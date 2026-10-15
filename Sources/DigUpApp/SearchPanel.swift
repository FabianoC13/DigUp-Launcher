import AppKit
import DigUpKit
import Observation
import Quartz
import SwiftUI

enum SearchPhase: Equatable {
    case empty       // nothing typed
    case words       // keyword results, meaning results on the way
    case meaning     // words + meaning: final
    case wordsOnly   // final, but there's no meaning search (the model is downloading, or the encoder failed)
    case codeHint    // "code:" and nothing yet: what to type
    case codeOff     // "code:" without code folders: how to turn code search on
    case launcher    // too short for a meaning search of files: the launcher's results only
}

/// The hotkey panel: type, see results grouped by kind with the selected one previewed big on the right, and open /
/// reveal / Quick Look / copy / drag them out.
///
/// Every keystroke shows keyword results at once (file names, OCR and document text, the last word as a prefix).
/// After a short pause in typing the query is embedded and the full hybrid results replace them. Results far weaker
/// than the best one are folded under "N weaker matches".
@Observable
final class SearchPanelController {
    static let width: CGFloat = 780
    static let listWidth: CGFloat = 330
    static let fieldHeight: CGFloat = 56
    static let expandedHeight: CGFloat = 480
    static let rowsPerGroup = 6
    static let typingPause: Duration = .milliseconds(120)
    /// It fades in and out, like Spotlight's panel.
    static let fadeIn: TimeInterval = 0.15
    static let fadeOut: TimeInterval = 0.12
    /// The selectable row that folds and unfolds the weaker matches.
    static let weakerToggle = "\u{0}weaker"

    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var results = ResultSet.empty
    private(set) var showWeaker = false
    private(set) var selection: String?
    private(set) var phase = SearchPhase.empty
    /// The query is a search of code ("code: …"): the code index, and nothing else.
    private(set) var isCode = false
    private(set) var note: String?
    var encoder: EngineStatus.Encoder { model.status.encoder }

    @ObservationIgnored let model: AppModel
    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private unowned let app: AppController
    @ObservationIgnored private var window: SearchPanelWindow?
    @ObservationIgnored weak var field: NSTextField?
    @ObservationIgnored private var generation = 0
    /// The generation whose final (meaning) results are showing; late keyword results must not replace them.
    @ObservationIgnored private var finalGeneration = -1
    @ObservationIgnored private var meaningTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var resignKeyObserver: NSObjectProtocol?
    /// Waits for the mouse button to come up after the panel lost the keys mid-click (`hideUnlessDragging`).
    @ObservationIgnored private var dragWatch: Timer?
    /// The glass behind the content (hidden when a look has no blur).
    @ObservationIgnored private var backdrop: NSView?
    @ObservationIgnored private var keyWindowObserver: NSObjectProtocol?
    @ObservationIgnored private var shownAt = Date.distantPast
    /// Fading out: still on screen, but gone as far as everything else is concerned.
    @ObservationIgnored private var fading = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// True once ↑/↓ moved the selection since the last edit: then Space previews instead of typing a space.
    @ObservationIgnored private var navigated = false
    @ObservationIgnored private var typedAt = Date()
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    /// Called when the final results for the current query are on screen (debug hooks use it).
    @ObservationIgnored var onFinalResults: (() -> Void)?
    /// Where ⌘C puts the file (debug runs use a private pasteboard so the real clipboard stays untouched).
    @ObservationIgnored var pasteboard = NSPasteboard.general

    // MARK: Launcher state
    /// A meaning search of files needs this many characters: fewer is an app or a command being typed.
    static let minFileQuery = 3
    /// The launcher's items for the query (root search), or the mode's list.
    private(set) var items: [LauncherItem] = []
    /// Modes pushed over the root search (Clipboard History, Quick AI…); the last one shows.
    private(set) var modes: [any LauncherMode] = []
    /// A picture is being dragged over the panel: it shows where it'll go.
    private(set) var dropTargeted = false
    /// ⌘K is open, on this action of the selected item.
    private(set) var actionsOpen = false
    private(set) var actionSelection = 0
    /// The app that was in front when the panel opened.
    @ObservationIgnored private(set) var previousApp: NSRunningApplication?
    @ObservationIgnored private var launcherTasks: [Task<Void, Never>] = []
    /// What was typed in the root search when a mode was pushed (it comes back when the mode is popped).
    @ObservationIgnored private var rootQuery = ""
    @ObservationIgnored private(set) lazy var context = LauncherContext(panel: self)
    var launcher: Launcher { app.launcher }
    var appController: AppController { app }
    var mode: (any LauncherMode)? { modes.last }

    init(app: AppController) {
        self.app = app
        model = app.model
        engine = app.engine
    }

    var isVisible: Bool { window?.isVisible == true && !fading }
    var windowNumber: Int { window?.windowNumber ?? 0 }
    var isPreviewing: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
    /// The selectable rows in order: the launcher's items before the files, the strong file results group by group,
    /// the fold, the weaker ones if unfolded, then the launcher's items after the files. A mode: its own list.
    var rowIDs: [String] {
        if mode != nil { return items.map(\.id) }
        return itemsBeforeFiles.map(\.id) + fileRowIDs + itemsAfterFiles.map(\.id)
    }
    var fileRowIDs: [String] {
        results.groups.flatMap { $0.rows.map(\.id) }
            + (results.weaker.isEmpty ? [] : [Self.weakerToggle])
            + (showWeaker ? results.weaker.map(\.id) : [])
    }
    var itemsBeforeFiles: [LauncherItem] { mode != nil ? items : items.filter { !$0.section.afterFiles } }
    var itemsAfterFiles: [LauncherItem] { mode != nil ? [] : items.filter(\.section.afterFiles) }
    var selectedItem: LauncherItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }
    /// The selected item's actions, with the launcher's own (favorites, alias, hotkey) after them; a file's actions.
    var selectedActions: [LauncherAction] {
        if let item = selectedItem {
            return item.actions + (item.tracksUsage ? Personalization.actions(for: item, context: context) : [])
        }
        if let row = selectedRow { return fileActions(row) }
        return []
    }
    /// The list has something to show: results, a mode, or suggestions with nothing typed.
    var showsList: Bool { phase != .empty || mode != nil || !items.isEmpty }
    var rows: [ResultRow] { results.groups.flatMap(\.rows) + (showWeaker ? results.weaker : []) }
    var selectedRow: ResultRow? { rows.first { $0.id == selection } }

    // MARK: Showing

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let started = Date()
        if !isVisible, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        let wasVisible = isVisible
        shownAt = started
        engine.prewarm()
        let window = self.window ?? makeWindow()
        placeWindow(window)
        if AppController.offscreen { return }
        // DigUp isn't activated (the panel takes the keys on its own), so you stay in the Space you're in, a
        // full-screen app's too. The activity keeps App Nap off instead: a background app's main thread drops to
        // efficiency cores, which can make search 5× slower.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Search panel open")
        }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }   // Esc, or a Quicklink, hid it
        fading = false   // shown again while it faded out: it comes back from where it got to
        window.ignoresMouseEvents = false
        window.canHide = true
        if !window.isVisible { window.alphaValue = 0 }
        window.orderFrontRegardless()
        window.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            window.animator().alphaValue = PanelAppearance.shared.look.opacity
        }
        if let field {
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)   // like Spotlight: the last query, selected
        }
        installKeyMonitor()
        // Favorites and suggestions with nothing typed (and the last query's results otherwise, fresh).
        if !wasVisible, mode == nil { runLauncher(query, generation: generation) }
        let shown = Date()
        DispatchQueue.main.async {
            // The next turn of the main loop, after the window's first layout and display.
            log("panel: shown in \(ms(since: started, until: shown)), drawn by \(ms(since: started))")
        }
    }

    func hide() {
        dragWatch?.invalidate()
        dragWatch = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        removeKeyMonitor()
        PreviewPlayback.shared.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        Thumbnails.shared.clear()
        Previews.shared.clear()
        actionsOpen = false
        if !modes.isEmpty { popToRoot() }
        guard let window, window.isVisible, !fading else { return }
        if !NSApp.isActive {
            // The usual case (not activated): gone at once, so the keys are back in the app you were in before
            // anything is pasted or typed there. While it faded it would keep them.
            window.orderOut(nil)
            window.canHide = true
            return
        }
        fading = true
        window.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOut
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fading else { return }   // shown again meanwhile
                self.fading = false
                window.orderOut(nil)
                window.canHide = true
            }
        }
    }

    // MARK: Searching

    private func queryChanged() {
        generation += 1
        let current = generation
        typedAt = Date()
        navigated = false
        actionsOpen = false
        meaningTask?.cancel()
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A mode searches its own list, nothing else.
        if let mode {
            isCode = false
            results = .empty
            phase = .launcher
            runMode(mode, query: query, generation: current)
            resizeWindow()
            return
        }
        let codeText = CodeQuery.text(of: typed)
        isCode = codeText != nil
        let code = isCode
        let text = codeText ?? typed
        if code {
            stopLauncher()
            items = []
        } else {
            runLauncher(query, generation: current)
        }
        guard !typed.isEmpty else {
            results = .empty
            selection = rowIDs.first
            phase = .empty
            resizeWindow()
            return
        }
        // One or two letters: an app or a command, not something to look for in files by meaning.
        if !code, typed.count < Self.minFileQuery {
            results = .empty
            phase = .launcher
            if !rowIDs.contains(where: { $0 == selection }) { selection = rowIDs.first }
            resizeWindow()
            return
        }
        // "code:" alone, or without code folders: what to do instead of results.
        if code, !model.hasCode || text.isEmpty {
            results = .empty
            selection = nil
            phase = model.hasCode ? .codeHint : .codeOff
            resizeWindow()
            return
        }
        // Words now. The last word is probably half-typed, so it matches as a prefix.
        Task {
            let started = Date()
            let hits = await engine.search(text, vector: nil, prefixLast: true, code: code)
            guard current == generation, finalGeneration != current else { return }
            show(hits, query: text, phase: .words)
            log("search \"\(typed)\": words \(hits.count) hits in \(ms(since: started))")
        }
        // Meaning results show once typing pauses, but they're computed now (embedding, then search), so they're
        // ready by then: the pause is the whole wait.
        engine.embedAhead(text, code: code)
        let showAt = ContinuousClock.now + Self.typingPause   // counted from the keystroke, not from when the task runs
        meaningTask = Task {
            let embedStarted = Date()
            let vector = await engine.embedQuery(text, code: code)
            guard !Task.isCancelled, current == generation else { return }
            let searchStarted = Date()
            let hits = await engine.search(text, vector: vector, prefixLast: false, code: code)
            let searched = Date()
            try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
            guard !Task.isCancelled, current == generation else { return }
            finalGeneration = current
            show(hits, query: text, phase: vector == nil ? .wordsOnly : .meaning)
            let shown = Date(), keystroke = typedAt
            log("search \"\(typed)\": \(vector == nil ? "words only" : "meaning") \(hits.count) hits "
                + "(\(results.strongRows.count) strong) · embed \(ms(since: embedStarted, until: searchStarted)) · "
                + "search \(ms(since: searchStarted, until: searched)) · shown \(ms(since: keystroke, until: shown)) after "
                + "the last keystroke")
            DispatchQueue.main.async {
                // The next turn of the main loop: the list and the preview pane have been laid out and drawn.
                log("search \"\(typed)\": drawn by \(ms(since: keystroke)) after the last keystroke")
            }
            onFinalResults?()
        }
    }

    private func show(_ hits: [SearchHit], query: String, phase: SearchPhase) {
        // Code is one group: it gets the room of all of them.
        results = ResultSet(hits, query: query, rowsPerGroup: isCode ? Self.rowsPerGroup * 3 : Self.rowsPerGroup)
        if !navigated { showWeaker = false }
        // Follow the top hit until you pick something with the arrow keys.
        if !navigated || !rowIDs.contains(where: { $0 == selection }) {
            selection = rowIDs.first
        }
        self.phase = phase
        resizeWindow()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { updateQuickLook() }
    }

    // MARK: Launcher

    private func stopLauncher() {
        for task in launcherTasks { task.cancel() }
        launcherTasks = []
    }

    /// The root search's providers, for what's typed; their items show as each one answers.
    private func runLauncher(_ text: String, generation current: Int) {
        stopLauncher()
        let typed = typedAt
        launcherTasks = launcher.search(LauncherQuery(text)) { [weak self] found, final in
            guard let self, current == generation, mode == nil else { return }
            showItems(found)
            if final {
                let shown = Date()
                DispatchQueue.main.async {
                    log("launcher \"\(text)\": \(found.count) items shown \(ms(since: typed, until: shown)), drawn by "
                        + "\(ms(since: typed)) after the keystroke")
                }
            }
            // Nothing else is coming when files aren't searched (debug hooks wait for this).
            if final, phase == .launcher || phase == .empty { onFinalResults?() }
        }
    }

    /// The mode's list for what's typed.
    private func runMode(_ mode: any LauncherMode, query text: String, generation current: Int) {
        stopLauncher()
        launcherTasks = [Task { [weak self] in
            let found = await mode.items(for: LauncherQuery(text))
            guard let self, !Task.isCancelled, current == generation, self.mode === mode else { return }
            showItems(found)
            onFinalResults?()
        }]
    }

    private func showItems(_ found: [LauncherItem]) {
        items = found
        // Follow the top row until you pick something with the arrow keys.
        if !navigated || !rowIDs.contains(where: { $0 == selection }) {
            selection = rowIDs.first
        }
        resizeWindow()
    }

    /// Searches again with what's typed (a mode's list changed).
    func refresh() {
        let selected = selection
        let wasNavigated = navigated
        queryChanged()
        navigated = wasNavigated
        selection = selected
    }

    /// Opens a mode over the root search.
    func push(_ mode: any LauncherMode, query initial: String = "") {
        if modes.isEmpty { rootQuery = query }
        modes.append(mode)
        actionsOpen = false
        items = []
        selection = nil
        if query == initial { queryChanged() } else { query = initial }
        resizeWindow()
        if let field { window?.makeFirstResponder(field) }
        field?.currentEditor()?.selectedRange = NSRange(location: (initial as NSString).length, length: 0)
    }

    /// Back one mode (to the root search from the first).
    func popMode() {
        guard let popped = modes.popLast() else { return }
        popped.didClose()
        actionsOpen = false
        items = []
        let restore = modes.isEmpty ? rootQuery : ""
        if query == restore { queryChanged() } else { query = restore }
        resizeWindow()
    }

    func popToRoot() {
        while !modes.isEmpty { popMode() }
    }

    /// Runs one of an item's actions: the panel hides first unless the action keeps it.
    func run(_ action: LauncherAction, of item: LauncherItem?, recordUsage: Bool = true) {
        if let item, recordUsage {
            launcher.recordUse(item, query: mode == nil ? query : nil)
        }
        actionsOpen = false
        if !action.keepsPanelOpen, isVisible { dismissForAction() }
        let context = self.context
        Task { await action.run(context) }
    }

    /// Hides the panel after an action: the keyboard goes back to the app you came from at once.
    func dismissForAction() {
        dismiss()
    }

    func flashNote(_ text: String) {
        flash(text)
    }

    /// Tab: the question to Quick AI.
    func askAI() {
        QuickAIFeature.ask(query.trimmingCharacters(in: .whitespacesAndNewlines), context: context)
    }

    /// ⌘K on a file result: what you'd do with a file.
    private func fileActions(_ row: ResultRow) -> [LauncherAction] {
        [
            LauncherAction(id: "open", title: row.openTitle, symbol: "arrow.up.forward.app") { [weak self] _ in
                self?.engine.open(row)
            },
            LauncherAction(id: "reveal", title: "Show in Finder", symbol: "folder") { _ in
                NSWorkspace.shared.activateFileViewerSelecting([row.url])
            },
            LauncherAction(id: "quicklook", title: "Quick Look", symbol: "eye", shortcut: LauncherShortcut("y", .command),
                           keepsPanelOpen: true) { [weak self] _ in self?.toggleQuickLook() },
            LauncherAction(id: "copy", title: "Copy File", symbol: "doc.on.doc", shortcut: .copy,
                           keepsPanelOpen: true) { [weak self] _ in self?.copySelected() },
            LauncherAction(id: "copy-path", title: "Copy Path", symbol: "link",
                           shortcut: LauncherShortcut("c", [.command, .shift]), keepsPanelOpen: true) { context in
                context.copy(row.url.path)
            },
            LauncherAction(id: "window", title: "Open in DigUp Window", symbol: "macwindow",
                           shortcut: LauncherShortcut("o", .command)) { [weak self] _ in self?.openInWindow() },
        ]
    }

    func toggleWeaker() {
        showWeaker.toggle()
        selection = Self.weakerToggle
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, self.owns(event) else { return event }
            return self.handle(event) ? nil : event
        }
        // A click back in the search field: Space types again (after a click on a result, it previewed).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let field, event.window === field.window else { return event }
            if field.bounds.contains(field.convert(event.locationInWindow, from: nil)) { navigated = false }
            return event
        }
        // A click in another app. The panel opens without activating DigUp, so that's the panel losing the keys to
        // no window of DigUp's; DigUp itself resigning, when it was active (Quick Look activates it).
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in   // once the new key window is set
                    guard let self, NSApp.keyWindow == nil, !PanelAppearance.shared.tuning else { return }
                    self.hideUnlessDragging()
                }
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // While the stealth tuning page is open, the panel stays up over the browser.
            MainActor.assumeIsolated { if !PanelAppearance.shared.tuning { self?.hideUnlessDragging() } }
        }
        // Another of the app's windows came forward (⌘, or ⌘N while the panel was up): the panel steps away, like
        // Spotlight, rather than float over it and take its keys.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, window !== self.window, !(window is QLPreviewPanel) else { return }
                if Date().timeIntervalSince(self.shownAt) < 0.5 {
                    // Activating the app can hand the key to its last window just after the panel opened: take it back.
                    self.window?.makeKey()
                } else {
                    self.hide()
                }
            }
        }
    }

    /// The panel lost the keys to another app. A click there can be the start of a drag towards the panel (a picture
    /// from Finder for Quick AI): while the button is held the panel waits, and when it's let go over the panel (the
    /// drop landed in the field) it stays and takes the keys back. Let go anywhere else, it hides.
    private func hideUnlessDragging() {
        guard NSEvent.pressedMouseButtons & 1 != 0, window?.isVisible == true, !fading else {
            hide()
            return
        }
        guard dragWatch == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDragEnded() }
        }
        RunLoop.main.add(timer, forMode: .common)   // .common: it also runs while a drag is being tracked
        dragWatch = timer
    }

    private func checkDragEnded() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        dragWatch?.invalidate()
        dragWatch = nil
        guard let window, window.isVisible, !fading else { return }
        if window.frame.contains(NSEvent.mouseLocation) {
            window.makeKeyAndOrderFront(nil)
            if let field { window.makeFirstResponder(field) }
        } else if NSApp.keyWindow == nil {
            hide()
        }
    }

    private func removeKeyMonitor() {
        for monitor in [keyMonitor, mouseMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        mouseMonitor = nil
        for observer in [resignObserver, resignKeyObserver, keyWindowObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        resignObserver = nil
        resignKeyObserver = nil
        keyWindowObserver = nil
    }

    /// Keys typed in the panel, or in Quick Look while the panel is the one showing it.
    private func owns(_ event: NSEvent) -> Bool {
        if event.window === window { return true }
        guard QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared() else { return false }
        return event.window === preview && preview.dataSource === window
    }

    /// True when the key was handled here (it then doesn't reach the search field).
    private func handle(_ event: NSEvent) -> Bool {
        // An input method is composing (Japanese, Chinese…): ↩, the arrows and Esc are its keys until it's done.
        if (field?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
        // The action panel (⌘K) has the keys while it's open.
        if actionsOpen {
            let actions = selectedActions
            switch event.keyCode {
            case 53:  // Esc
                actionsOpen = false
            case 125, 126:  // ↓ ↑
                guard !actions.isEmpty else { return true }
                actionSelection = max(0, min(actions.count - 1, actionSelection + (event.keyCode == 125 ? 1 : -1)))
            case 36, 76:  // ↩
                if actions.indices.contains(actionSelection) { run(actions[actionSelection], of: selectedItem) }
            case 40 where modifiers == .command:  // ⌘K
                actionsOpen = false
            default:
                if let action = actions.first(where: { $0.shortcut?.matches(event) == true }) {
                    run(action, of: selectedItem)
                } else {
                    return false
                }
            }
            return true
        }
        if event.keyCode == 53 {  // Esc
            if previewing {
                QLPreviewPanel.shared().orderOut(nil)
            } else if mode != nil {
                popMode()
            } else {
                dismiss()
            }
            return true
        }
        if event.keyCode == 40, modifiers == .command, !selectedActions.isEmpty {  // ⌘K
            actionSelection = 0
            actionsOpen = true
            return true
        }
        if let mode {
            if mode.handle(event, query: query, context: context) { return true }
            // ⌫ in an empty field goes back, like Raycast.
            if event.keyCode == 51, modifiers.isEmpty, query.isEmpty {
                popMode()
                return true
            }
        } else if event.keyCode == 48, modifiers.isEmpty, !isCode {  // Tab: ask AI
            askAI()
            return true
        }
        // The selected item's own shortcuts (⌘C, ⌃X…).
        // ↩ and ⌘↩ are the first two actions', below.
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if let item = selectedItem, !(isReturn && (modifiers.isEmpty || modifiers == .command)),
           let action = selectedActions.first(where: { $0.shortcut?.matches(event) == true }) {
            run(action, of: item)
            return true
        }
        switch event.keyCode {
        case 125, 126:  // ↓ ↑
            guard modifiers.isEmpty else { return false }
            moveSelection(by: event.keyCode == 125 ? 1 : -1)
            navigated = true
            return true
        case 36, 76:  // ↩, enter
            if let item = selectedItem {
                if modifiers.isEmpty, let action = item.primary {
                    run(action, of: item)
                } else if modifiers == .command, let action = item.secondary {
                    run(action, of: item)
                } else {
                    return false
                }
            } else if selection == Self.weakerToggle, modifiers.isEmpty {
                toggleWeaker()
            } else if modifiers == .command {
                revealSelected()
            } else if modifiers.isEmpty {
                openSelected()
            } else {
                return false
            }
            return true
        case 49 where modifiers.isEmpty && (navigated || previewing) && selectedRow != nil:  // Space
            toggleQuickLook()
            return true
        case 49 where modifiers.isEmpty && navigated && selection == Self.weakerToggle:
            toggleWeaker()
            return true
        case 16 where modifiers == .command && selectedRow != nil:  // ⌘Y
            toggleQuickLook()
            return true
        case 31 where modifiers == .command && mode == nil:  // ⌘O: the same search in the window, for a bigger look
            openInWindow()
            return true
        case 8 where modifiers == .command && selectedRow != nil:
            // ⌘C copies the selected file, except right after you selected some of the query text (the panel opens
            // with the last query selected, and arrowing to a result means you want the file).
            let textSelected = (field?.currentEditor()?.selectedRange.length ?? 0) > 0
            if textSelected, !navigated { return false }
            copySelected()
            return true
        default:
            return false
        }
    }

    func moveSelection(by step: Int) {
        let ids = rowIDs
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, index + step))]
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { updateQuickLook() }
    }

    func select(_ row: ResultRow) {
        selection = row.id
        navigated = true
    }

    func select(_ item: LauncherItem) {
        selection = item.id
        navigated = true
        actionsOpen = false
    }

    // MARK: Actions

    /// ↩: the file in its app, at the page or moment that matched when the app can be told where.
    func openSelected() {
        guard let row = selectedRow else { return }
        engine.open(row)
        hide()
    }

    func revealSelected() {
        guard let row = selectedRow else { return }
        NSWorkspace.shared.activateFileViewerSelecting([row.url])
        hide()
    }

    func copySelected() {
        guard let row = selectedRow else { return }
        pasteboard.clearContents()
        // As a file, like ⌘C in Finder: paste into a folder, a chat or a mail.
        pasteboard.writeObjects([row.url as NSURL])
        flash("Copied \(row.name)")
    }

    /// The search window, with this query (and only one kind, if given): for a bigger look.
    func openInWindow(_ kind: ResultGroupKind? = nil) {
        let text = query
        hide()
        app.showSearchWindow(query: text, kind: kind)
    }

    /// No folders yet: hide, and open where they're chosen.
    func chooseFolders() {
        hide()
        app.chooseFolders()
    }

    /// "code:" without code search: hide, and open where code folders are chosen.
    func setUpCodeSearch() {
        hide()
        app.chooseCodeFolders()
    }

    /// An example from the code hint, as if typed.
    func tryExample(_ text: String) {
        query = text
    }

    /// Esc: hide, and give the keyboard back to the app you came from (at once: the fade doesn't hold it).
    private func dismiss() {
        // Not activated, the app you came from still has the keyboard: the panel just goes.
        guard NSApp.isActive else { return hide() }
        // Hiding the app gives the keyboard back at once; the panel is left out of it so that it can still fade.
        window?.canHide = false
        hide()
        NSApp.hide(nil)
    }

    private func flash(_ text: String) {
        note = text
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            note = nil
        }
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        let panel = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else if selectedRow != nil {
            updateQuickLook()
            // Quick Look takes the keys only from an active app. With the panel up in this Space, activating DigUp
            // keeps you in it, and Quick Look joins it over a full-screen app.
            bringAppToFront()
            panel.collectionBehavior.insert(.fullScreenAuxiliary)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Quick Look shows the selected result at its page or moment.
    private func updateQuickLook() {
        window?.previewURL = selectedRow?.url
        QLPreviewPanel.shared().reloadData()
        QuickLookMoment.show(selectedRow, in: QLPreviewPanel.shared())
    }

    // MARK: Window

    private func makeWindow() -> SearchPanelWindow {
        let window = SearchPanelWindow()
        let hosting = NSHostingView(rootView: SearchPanelView(controller: self))
        hosting.sizingOptions = []
        let container = Self.background(containing: hosting)
        window.contentView = container
        backdrop = container.subviews.first
        // A picture dropped anywhere on the panel (the field has its own copy of this) opens Quick AI with it attached.
        container.onImages = { [weak self] images in
            guard let self else { return }
            dropTargeted = false
            QuickAIFeature.attachImages(images, context: context)
        }
        container.onTargeted = { [weak self] targeted in self?.dropTargeted = targeted }
        self.window = window
        PanelAppearance.shared.onChange.append { [weak self] in self?.applyAppearance() }
        applyAppearance()
        return window
    }

    /// Normal or Stealth (or a look being tuned): the window's alpha and the blur. The tint is the view's.
    func applyAppearance() {
        let look = PanelAppearance.shared.look
        backdrop?.isHidden = !look.blur
        guard let window, window.isVisible, !fading else { return }
        window.alphaValue = look.opacity
    }

    private var desiredHeight: CGFloat {
        showsList ? Self.expandedHeight : Self.fieldHeight
    }

    /// Centered on the screen with the pointer, a little above the middle, like Spotlight.
    private func placeWindow(_ window: NSWindow) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = area.maxY - area.height * 0.16
        let height = desiredHeight
        window.setFrame(NSRect(x: area.midX - Self.width / 2, y: top - height, width: Self.width, height: height),
                        display: true)
    }

    /// Grows or shrinks downward, keeping the search field where it is.
    private func resizeWindow() {
        guard let window else { return }
        let height = desiredHeight
        guard abs(window.frame.height - height) > 0.5 else { return }
        // Not in the middle of a SwiftUI update: resizing from inside one sizes the view wrong.
        DispatchQueue.main.async {
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }
    }

    /// Glass (or vibrancy before macOS 26) behind the SwiftUI content. The content sits beside the glass rather than
    /// inside it, since NSGlassEffectView resizes its contentView itself.
    private static func background(containing content: NSView) -> PanelDropView {
        let radius: CGFloat = 18
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            backdrop = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = radius
            effect.layer?.masksToBounds = true
            backdrop = effect
        }
        let container = PanelDropView()
        for view in [backdrop, content] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        return container
    }

    /// Draws the panel into a PNG (see `Snapshot`); the glass doesn't draw that way, so it's on the window color.
    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url, cornerRadius: 18)
    }
}

/// The panel's root view: takes pictures dropped anywhere on it (the views inside don't take drags, so they come
/// here), for Quick AI.
final class PanelDropView: NSView {
    var onImages: ([QuickAIPendingImage]) -> Void = { _ in }
    var onTargeted: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                 NSPasteboard.PasteboardType("public.heic")])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard QuickAIImages.canAccept(sender) else { return [] }
        onTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        QuickAIImages.canAccept(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        QuickAIImages.canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = QuickAIImages.fromDraggingInfo(sender)
        onTargeted(false)
        guard !images.isEmpty else { return false }
        onImages(images)
        return true
    }
}

/// The floating panel. Unlike most floating panels it becomes key, because you type into it. It does so without
/// activating DigUp, like Spotlight's: activating would take you out of a full-screen app to the desktop.
final class SearchPanelWindow: NSPanel, QLPreviewPanelDataSource {
    /// What Space / ⌘Y previews.
    var previewURL: URL?
    /// Shared field editor so image drops/pastes on the search field attach files instead of pasting paths.
    private var digUpFieldEditor: DigUpFieldEditor?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: SearchPanelController.width,
                                       height: SearchPanelController.fieldHeight),
                   styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false   // the controller hides it, and also tidies up
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        guard let field = object as? FocusReportingField else {
            return super.fieldEditor(createFlag, for: object)
        }
        if digUpFieldEditor == nil {
            let editor = DigUpFieldEditor(frame: .zero)
            editor.isFieldEditor = true
            editor.registerForDraggedTypes([.fileURL, .png, .tiff,
                                           NSPasteboard.PasteboardType("public.jpeg"),
                                           NSPasteboard.PasteboardType("public.heic")])
            digUpFieldEditor = editor
        }
        digUpFieldEditor?.digUpField = field
        return digUpFieldEditor
    }

    // Quick Look asks the responder chain who controls it; the panel does. (These come from a nonisolated NSObject
    // category; Quick Look calls them on the main thread.)
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            // Above the floating search panel.
            panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}

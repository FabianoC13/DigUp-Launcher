import AppKit
import DigUpKit
import Observation
import SwiftUI

/// What the note window shows: one note at a time, with the notes opened before and after it.
@Observable
final class NoteEditor {
    private(set) var noteID: String?
    private(set) var text = ""
    private(set) var back: [String] = []
    private(set) var forward: [String] = []

    var title: String { NotesText.title(of: text) }

    /// Shows another note; `remember` keeps the current one for ⌘[.
    func load(_ note: NoteFile, remember: Bool = true) {
        if remember, let current = noteID, current != note.id {
            back.append(current)
            forward = []
        }
        noteID = note.id
        text = note.text
    }

    func typed(_ text: String) {
        self.text = text
    }

    func popBack() -> String? {
        guard let id = back.popLast() else { return nil }
        if let current = noteID { forward.append(current) }
        return id
    }

    func popForward() -> String? {
        guard let id = forward.popLast() else { return nil }
        if let current = noteID { back.append(current) }
        return id
    }

    /// Forgets a note that's gone.
    func drop(_ id: String) {
        back.removeAll { $0 == id }
        forward.removeAll { $0 == id }
        if noteID == id {
            noteID = nil
            text = ""
        }
    }
}

/// The floating note window: a Markdown note that saves itself half a second after you stop typing, above every app
/// and on every Space, where you left it (its frame is remembered). Esc closes it.
///
/// Keys: ⌘N new note, ⌘[ ⌘] the notes opened before and after, ⌘P all notes (in the launcher), ⇧⌘P pin, ⌘⌫ delete,
/// ⌘+ ⌘- ⌘0 text size, ⌘B ⌘I ⌘E ⇧⌘S bold, italic, code, strikethrough, ⌥⌘1–3 headings, ⇧⌘7 ⇧⌘8 ⇧⌘9 numbered,
/// bulleted and task lists, ⇧⌘B quote, ⌘↩ checks a task.
final class NotesWindowController: NSObject, NSWindowDelegate {
    static let shared = NotesWindowController()

    let editor = NoteEditor()
    private let store = NotesStore.shared
    private var panel: NotePanel?
    private var keyMonitor: Any?
    /// The app in front before the window came up: it gets the keyboard back when the window closes.
    private var previousApp: NSRunningApplication?
    weak var launcher: Launcher?
    static let frameName = "DigUp Launcher Note"

    var isVisible: Bool { panel?.isVisible == true }
    var isKey: Bool { panel?.isKeyWindow == true }

    // MARK: Opening

    func open(_ id: String) {
        guard let note = store.note(id) else {
            ProductivityHUD.show("That note is gone", symbol: "note.text")
            return
        }
        show(note)
    }

    /// A new note, with `text` in it.
    func openNew(text: String = "") {
        show(store.create(text: text))
    }

    /// The note opened last, or a new one when there are none.
    func openLast() {
        if let note = store.lastOpened { show(note) } else { openNew() }
    }

    /// Open Last Note's hotkey behavior: shows the window, or closes it when it's already in front.
    func toggle() {
        if isVisible, isKey { close() } else if isVisible, let panel { present(panel) } else { openLast() }
    }

    private func show(_ note: NoteFile, remember: Bool = true) {
        switchAway(to: note.id)
        editor.load(note, remember: remember)
        store.opened(note.id)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.title = note.title
        present(panel)
    }

    private func present(_ panel: NotePanel) {
        let front = NSWorkspace.shared.frontmostApplication
        if !panel.isVisible || front?.processIdentifier != getpid() {
            previousApp = front?.processIdentifier == getpid() ? previousApp : front
        }
        bringAppToFront()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        // The text view exists once SwiftUI has laid the window out.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let textView = Self.findTextView(in: panel.contentView) else { return }
            panel.makeFirstResponder(textView)
        }
    }

    /// Leaving the current note for another: its last change is written, and an empty one goes.
    private func switchAway(to next: String?) {
        guard let current = editor.noteID, current != next else { return }
        store.flush(current)
        if store.note(current)?.isBlank == true {
            store.discardIfBlank(current)
            editor.drop(current)
        }
    }

    func close() {
        panel?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let current = editor.noteID {
            store.flush(current)
            if store.note(current)?.isBlank == true {
                store.discardIfBlank(current)
                editor.drop(current)
            }
        }
        removeKeyMonitor()
        let previous = previousApp
        previousApp = nil
        // The keyboard goes back to where it was, unless another of DigUp's windows is in use.
        let othersOpen = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        if !othersOpen { previous?.activate() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let current = editor.noteID { store.flush(current) }
    }

    // MARK: Editing

    /// The editor's text changed (typing): kept now, saved a moment later.
    func typed(_ text: String) {
        guard let id = editor.noteID else { return }
        editor.typed(text)
        store.update(id, text: text)
        panel?.title = editor.title
    }

    func goBack() {
        while let id = editor.popBack() {
            if let note = store.note(id) {
                switchAway(to: id)
                editor.load(note, remember: false)
                store.opened(id)
                panel?.title = note.title
                return
            }
        }
    }

    func goForward() {
        while let id = editor.popForward() {
            if let note = store.note(id) {
                switchAway(to: id)
                editor.load(note, remember: false)
                store.opened(id)
                panel?.title = note.title
                return
            }
        }
    }

    func togglePin() {
        guard let id = editor.noteID else { return }
        store.togglePin(id)
    }

    /// Deletes the note in the window (to the Trash, after asking), and shows the one opened before it.
    func deleteCurrent() {
        guard let id = editor.noteID, let note = store.note(id) else { return }
        if !note.isBlank {
            let alert = NSAlert()
            alert.messageText = "Delete “\(note.title)”?"
            alert.informativeText = "The note goes to the Trash."
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.delete(id)
        editor.drop(id)
        if let previous = editor.back.last.flatMap({ store.note($0) }) ?? store.lastOpened {
            editor.load(previous, remember: false)
            panel?.title = previous.title
        } else {
            close()
        }
    }

    /// All notes, in the launcher's Search Notes.
    func browse() {
        guard let context = launcher?.panel?.context else { return }
        context.push(NotesSearchMode())
    }

    func zoom(by step: Double?) {
        store.setFontSize(step.map { store.state.fontSize + $0 } ?? 14)
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handle(event, in: panel) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent, in panel: NotePanel) -> Bool {
        let textView = panel.firstResponder as? NSTextView
        if textView?.hasMarkedText() == true { return false }   // an input method is composing
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, flags) {
        case (53, []): close()
        case (45, .command): openNew()
        case (33, .command): goBack()
        case (30, .command): goForward()
        case (35, .command): browse()
        case (35, [.command, .shift]): togglePin()
        case (51, .command): deleteCurrent()
        case (24, .command), (24, [.command, .shift]), (69, .command): zoom(by: 1)
        case (27, .command), (78, .command): zoom(by: -1)
        case (29, .command): zoom(by: nil)
        case (11, .command): wrap("**", in: textView)
        case (34, .command): wrap("_", in: textView)
        case (14, .command): wrap("`", in: textView)
        case (1, [.command, .shift]): wrap("~~", in: textView)
        case (18, [.command, .option]): edit(lines: { NotesEditing.toggle(.heading(1), line: $0) }, in: textView)
        case (19, [.command, .option]): edit(lines: { NotesEditing.toggle(.heading(2), line: $0) }, in: textView)
        case (20, [.command, .option]): edit(lines: { NotesEditing.toggle(.heading(3), line: $0) }, in: textView)
        case (26, [.command, .shift]): edit(lines: { NotesEditing.toggle(.numbered, line: $0) }, in: textView)
        case (28, [.command, .shift]): edit(lines: { NotesEditing.toggle(.bullet, line: $0) }, in: textView)
        case (25, [.command, .shift]): edit(lines: { NotesEditing.toggle(.task, line: $0) }, in: textView)
        case (11, [.command, .shift]): edit(lines: { NotesEditing.toggle(.quote, line: $0) }, in: textView)
        case (36, .command), (76, .command): edit(lines: NotesEditing.toggleTask(line:), in: textView)
        default: return false
        }
        return true
    }

    /// Changes every line the selection touches (as one undoable edit).
    private func edit(lines change: (String) -> String, in textView: NSTextView?) {
        guard let textView else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let range = text.lineRange(for: selection)
        let original = text.substring(with: range)
        let endsWithNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }
        let replacement = lines.map(change).joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard replace(range, with: replacement, in: textView) else { return }
        let end = range.location + (replacement as NSString).length - (endsWithNewline ? 1 : 0)
        textView.setSelectedRange(NSRange(location: end, length: 0))
    }

    /// Puts `mark` around the selection, or takes it away when it's there.
    private func wrap(_ mark: String, in textView: NSTextView?) {
        guard let textView else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let length = (mark as NSString).length
        let beforeStart = max(0, selection.location - length)
        let before = text.substring(with: NSRange(location: beforeStart, length: selection.location - beforeStart))
        let afterEnd = min(text.length, NSMaxRange(selection) + length)
        let after = text.substring(with: NSRange(location: NSMaxRange(selection), length: afterEnd - NSMaxRange(selection)))
        let (replacement, outside) = NotesEditing.wrap(text.substring(with: selection), mark: mark, before: before,
                                                       after: after)
        let range = NSRange(location: selection.location - outside, length: selection.length + 2 * outside)
        guard replace(range, with: replacement, in: textView) else { return }
        let added = (replacement as NSString).length > selection.length + 2 * outside
        textView.setSelectedRange(added ? NSRange(location: range.location + length, length: selection.length)
                                        : NSRange(location: range.location, length: (replacement as NSString).length))
    }

    /// An edit the text view can undo, and that reaches the note (its delegate tells SwiftUI).
    private func replace(_ range: NSRange, with replacement: String, in textView: NSTextView) -> Bool {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        return true
    }

    // MARK: Window

    private func makePanel() -> NotePanel {
        let panel = NotePanel()
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: NoteWindowView(editor: editor, store: store, controller: self))
        if !panel.setFrameUsingName(Self.frameName) {
            // First time: on the right of the screen with the pointer.
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrame(NSRect(x: area.maxX - 460, y: area.maxY - 560, width: 420, height: 500), display: false)
        }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView, textView.isEditable { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }
}

/// A titled, resizable panel that floats above other apps' windows, on every Space and over full-screen apps.
final class NotePanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 280, height: 200)
        titlebarAppearsTransparent = true
        tabbingMode = .disallowed
    }

    override var canBecomeKey: Bool { true }
}

private struct NoteWindowView: View {
    @Bindable var editor: NoteEditor
    @Bindable var store: NotesStore
    let controller: NotesWindowController

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: Binding(get: { editor.text }, set: { controller.typed($0) }))
                .font(.system(size: store.state.fontSize, design: store.state.monospaced ? .monospaced : .default))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.top, 4)
            Divider()
            bar
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var pinned: Bool { editor.noteID.map { store.isPinned($0) } ?? false }

    private var bar: some View {
        HStack(spacing: 12) {
            Button { controller.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(editor.back.isEmpty)
                .help("Previous note (⌘[)")
            Button { controller.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(editor.forward.isEmpty)
                .help("Next note (⌘])")
            let words = NotesEditing.wordCount(editor.text)
            Text(words == 1 ? "1 word" : "\(words) words")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button { controller.togglePin() } label: { Image(systemName: pinned ? "pin.fill" : "pin") }
                .help(pinned ? "Unpin (⇧⌘P)" : "Pin (⇧⌘P)")
            Button { store.setMonospaced(!store.state.monospaced) } label: {
                Image(systemName: store.state.monospaced ? "textformat" : "chevron.left.forwardslash.chevron.right")
            }
            .help(store.state.monospaced ? "Proportional font" : "Monospaced font")
            Button { controller.browse() } label: { Image(systemName: "list.bullet") }
                .help("All notes (⌘P)")
            Button { controller.openNew() } label: { Image(systemName: "square.and.pencil") }
                .help("New note (⌘N)")
            Button { controller.deleteCurrent() } label: { Image(systemName: "trash") }
                .help("Delete note (⌘⌫)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}

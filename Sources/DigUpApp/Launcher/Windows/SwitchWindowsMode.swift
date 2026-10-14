import AppKit
import DigUpKit

extension WindowsFeature {
    /// Brings an app forward while DigUp is still the active app (macOS lets the active app hand activation over, and
    /// may refuse an app in the background), and waits a moment for it to happen.
    static func bringForward(_ app: NSRunningApplication) async {
        if app.isHidden { app.unhide() }
        app.activate(from: NSRunningApplication.current, options: [])
        for _ in 0..<15 where !app.isActive {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// One window of a running app, as the Accessibility API lists it (windows on the current Space, and minimized
    /// ones).
    nonisolated struct WindowInfo: Sendable {
        let window: Element
        let pid: pid_t
        let title: String
        let minimized: Bool
        /// The window server's id, for a stable item id and the front-to-back order.
        let windowID: CGWindowID?
        /// Its place in the app's window list, when there's no window id.
        let index: Int
    }

    /// Switch Windows: every window of the apps with a Dock icon, front to back. ↩ brings it forward; ⌘K closes,
    /// minimizes, hides or quits.
    final class SwitchWindowsMode: LauncherMode {
        let title = "Switch Windows"
        let placeholder = "Search windows by title or app…"
        let icon = LauncherIcon.symbol("macwindow.on.rectangle")

        /// The apps the windows belong to, by pid: name and icon (read on the main thread).
        private var apps: [pid_t: NSRunningApplication] = [:]
        private var load: Task<[WindowInfo], Never>
        private var loaded: [WindowInfo]?

        init() {
            load = Task { [] }
            reload()
        }

        /// Lists the windows again (after one was closed or minimized).
        func reload() {
            let own = ProcessInfo.processInfo.processIdentifier
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.processIdentifier != own && !$0.isTerminated
            }
            apps = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
            let pids = running.map(\.processIdentifier)
            loaded = nil
            load = Task.detached(priority: .userInitiated) { WindowsFeature.listWindows(pids: pids) }
        }

        func items(for query: LauncherQuery) async -> [LauncherItem] {
            let windows = await load.value
            guard !Task.isCancelled else { return [] }
            loaded = windows
            let section = LauncherSection.named("Windows", order: 0)
            var scored: [(item: LauncherItem, score: Double, order: Int)] = []
            for (order, info) in windows.enumerated() {
                guard let app = apps[info.pid] else { continue }
                let appName = app.localizedName ?? "App"
                let title = info.title.isEmpty ? appName : info.title
                var score = 1.0
                if !query.isEmpty {
                    guard let match = query.match(title, keywords: [appName]) else { continue }
                    score = match
                }
                scored.append((item(info, app: app, title: title, appName: appName, section: section), score, order))
            }
            return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.item)
        }

        var statusHint: String? {
            guard let loaded else { return "Listing windows…" }
            return loaded.count == 1 ? "1 window" : "\(loaded.count) windows"
        }

        private func item(_ info: WindowInfo, app: NSRunningApplication, title: String, appName: String,
                          section: LauncherSection) -> LauncherItem {
            let key = info.windowID.map { "window/\($0)" } ?? "window/\(info.pid)/\(info.index)"
            var accessory: String?
            if info.minimized { accessory = "Minimized" } else if app.isHidden { accessory = "Hidden" }
            let icon: LauncherIcon = app.icon.map { .image($0) }
                ?? app.bundleURL.map { .file($0) } ?? .symbol("macwindow")
            let window = info.window, pid = info.pid
            var actions = [
                LauncherAction(id: "switch", title: "Switch to Window", symbol: "macwindow",
                               keepsPanelOpen: true) { context in
                    await Task.detached { AX.raise(window, pid: pid) }.value
                    await WindowsFeature.bringForward(app)
                    context.hide()
                },
                LauncherAction(id: "close", title: "Close Window", symbol: "xmark.square",
                               shortcut: LauncherShortcut("w", .command), keepsPanelOpen: true) { [weak self] context in
                    let closed = await Task.detached { () -> Bool in
                        guard let button = AX.element(window, kAXCloseButtonAttribute) else { return false }
                        return AX.perform(button, kAXPressAction) == .success
                    }.value
                    if !closed { context.flash("This window can't be closed from here") }
                    await self?.reloadSoon(context)
                },
            ]
            if !info.minimized {
                actions.append(LauncherAction(id: "minimize", title: "Minimize Window", symbol: "minus.rectangle",
                                              shortcut: LauncherShortcut("m", .command),
                                              keepsPanelOpen: true) { [weak self] context in
                    let done = await Task.detached { AX.set(window, kAXMinimizedAttribute, kCFBooleanTrue) }.value
                    if !done { context.flash("This window can't be minimized") }
                    await self?.reloadSoon(context)
                })
            }
            actions += [
                LauncherAction(id: "fullscreen", title: "Enter Full Screen",
                               symbol: "arrow.up.backward.and.arrow.down.forward.square",
                               shortcut: LauncherShortcut("f", [.control, .command]), keepsPanelOpen: true) { context in
                    await Task.detached { AX.raise(window, pid: pid) }.value
                    await WindowsFeature.bringForward(app)
                    context.hide()
                    let done = await Task.detached { AX.set(window, "AXFullScreen", kCFBooleanTrue) }.value
                    if !done { SystemHUD.show("\(appName) can't go full screen", symbol: "exclamationmark.triangle") }
                },
                LauncherAction(id: "hide-app", title: "Hide \(appName)", symbol: "eye.slash",
                               shortcut: LauncherShortcut("h", .command), keepsPanelOpen: true) { [weak self] context in
                    app.hide()
                    await self?.reloadSoon(context)
                },
                LauncherAction(id: "quit-app", title: "Quit \(appName)", symbol: "xmark.circle",
                               shortcut: LauncherShortcut("q", .control), style: .destructive,
                               keepsPanelOpen: true) { [weak self] context in
                    app.terminate()
                    await self?.reloadSoon(context)
                },
            ]
            return LauncherItem(id: "\(WindowsFeature.prefix):\(key)", title: title, subtitle: appName, icon: icon,
                                accessory: accessory, section: section, actions: actions,
                                metadata: [("App", appName), ("State", info.minimized ? "Minimized" : "Open")],
                                tracksUsage: false)
        }

        /// The app gets a moment to act (a close can ask to save first), then the list is read again.
        private func reloadSoon(_ context: LauncherContext) async {
            try? await Task.sleep(for: .milliseconds(250))
            reload()
            context.refresh()
        }
    }

    /// Each app's windows as they come in from `concurrentPerform`.
    nonisolated private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var windows: [[WindowInfo]]

        init(count: Int) {
            windows = Array(repeating: [], count: count)
        }

        func set(_ list: [WindowInfo], at index: Int) {
            lock.withLock { windows[index] = list }
        }

        var all: [WindowInfo] { lock.withLock { windows.flatMap { $0 } } }
    }

    /// The windows of these apps, front to back as the window server stacks them; minimized ones and those on other
    /// Spaces last. The apps are asked at the same time, so a slow one only holds up itself.
    nonisolated static func listWindows(pids: [pid_t]) -> [WindowInfo] {
        let found = Collected(count: pids.count)
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            let pid = pids[index]
            var windows: [WindowInfo] = []
            for (position, window) in AX.elements(AX.application(pid), kAXWindowsAttribute).enumerated() {
                let values = AX.values(window, [kAXTitleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute])
                let title = (values[0] as? String) ?? ""
                let subrole = (values[1] as? String) ?? ""
                // Documents, browsers and dialogs; not tooltips, popovers or untitled panels.
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
                    || (!title.isEmpty && subrole != kAXUnknownSubrole) else { continue }
                windows.append(WindowInfo(window: window, pid: pid, title: title,
                                          minimized: (values[2] as? NSNumber)?.boolValue ?? false,
                                          windowID: AX.windowID(window), index: position))
            }
            found.set(windows, at: index)
        }
        let stack = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let depth = Dictionary(stack.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let all = found.all
        return all.enumerated().sorted { a, b in
            let da = a.element.windowID.flatMap { depth[$0] } ?? Int.max
            let db = b.element.windowID.flatMap { depth[$0] } ?? Int.max
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
    }
}

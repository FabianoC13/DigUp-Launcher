import AppKit
import DigUpKit

extension WindowsFeature {
    /// What the front window is like before a command moves it.
    private struct FrontWindow: Sendable {
        let window: Element
        let frame: LauncherWindowRect
        let fullScreen: Bool
        /// Restore's memory is keyed by it: the window server's id, else the app and the title.
        let key: String
    }

    /// For Restore: where a window was before the first of the layouts since you last moved it yourself, and where
    /// the last one put it.
    private struct Remembered {
        var before: LauncherWindowRect
        var placed: LauncherWindowRect
    }

    private static var remembered: [String: Remembered] = [:]
    private static var rememberedOrder: [String] = []
    private static let rememberedLimit = 100

    /// A layout, Restore, another display or full screen, for the front window of the app you came from.
    static func arrange(_ action: Action, context: LauncherContext) async {
        guard let app = SystemFeature.appInFront(context), !app.isTerminated else {
            SystemHUD.report("Open the launcher over a window to arrange it", symbol: "macwindow", context: context)
            return
        }
        let displays = Display.all()
        let gap = gap
        context.hide()
        let pid = app.processIdentifier
        let name = app.localizedName ?? "The app"
        guard let front = await Task.detached(operation: { readFrontWindow(pid: pid) }).value else {
            SystemHUD.show("\(name) has no window to arrange", symbol: "macwindow")
            return
        }
        if case .toggleFullScreen = action {
            let ok = await Task.detached {
                AX.set(front.window, "AXFullScreen", front.fullScreen ? kCFBooleanFalse : kCFBooleanTrue)
            }.value
            if !ok { SystemHUD.show("\(name) can't go full screen", symbol: "exclamationmark.triangle") }
            return
        }
        guard !front.fullScreen else {
            SystemHUD.show("The window is in full screen: leave it first", symbol: "arrow.down.right.and.arrow.up.left")
            return
        }
        let visible = displays.map(\.visible)
        guard let screenIndex = LauncherWindowGeometry.screenIndex(of: front.frame, in: visible) else { return }
        var screen = visible[screenIndex]
        let target: LauncherWindowRect
        switch action {
        case .layout(let layout):
            target = LauncherWindowGeometry.frame(for: layout, window: front.frame, screen: screen, gap: gap)
        case .restore:
            guard let saved = remembered[front.key] else {
                SystemHUD.show("Nothing to restore: this window hasn't been moved", symbol: "arrow.uturn.backward")
                return
            }
            target = saved.before
            screen = visible[LauncherWindowGeometry.screenIndex(of: target, in: visible) ?? screenIndex]
        case .display(let step):
            guard visible.count > 1 else {
                SystemHUD.show("There's only one display", symbol: "display")
                return
            }
            let next = LauncherWindowGeometry.neighbor(of: screenIndex, in: visible, step: step)
            target = LauncherWindowGeometry.transfer(front.frame, from: screen, to: visible[next])
            screen = visible[next]
        case .toggleFullScreen, .switchWindows, .searchMenuItems:
            return
        }
        var restoring = false
        if case .restore = action { restoring = true }
        remember(front, target: target, restoring: restoring)
        let placed = await Task.detached { place(front.window, at: target, within: screen, pid: pid) }.value
        if let placed {
            // What the app made of it (a minimum size, a terminal's character cells), for the next command.
            if !restoring { remembered[front.key]?.placed = placed }
        } else {
            log("windows: \(name) didn't take a new frame")
            SystemHUD.show("\(name) won't let its window be moved", symbol: "exclamationmark.triangle")
        }
    }

    /// The app's front window, its frame, and whether it's in full screen (off the main thread).
    nonisolated private static func readFrontWindow(pid: pid_t) -> FrontWindow? {
        guard let window = AX.frontWindow(of: pid), let frame = AX.frame(of: window) else { return nil }
        let key = AX.windowID(window).map { "id:\($0)" }
            ?? "app:\(pid):\(AX.string(window, kAXTitleAttribute) ?? "")"
        return FrontWindow(window: window, frame: frame, fullScreen: AX.isFullScreen(window), key: key)
    }

    /// Moves the window, then, when the app kept it bigger than asked (a minimum size) and it now hangs off the
    /// display, moves it back inside. Where it ended up; nil when the app refused.
    nonisolated private static func place(_ window: Element, at target: LauncherWindowRect,
                                          within screen: LauncherWindowRect, pid: pid_t) -> LauncherWindowRect? {
        guard let placed = AX.setFrame(window, to: target, pid: pid) else { return nil }
        let inside = LauncherWindowGeometry.clamped(placed, to: screen)
        guard abs(inside.x - placed.x) > 1 || abs(inside.y - placed.y) > 1 else { return placed }
        AX.setPosition(window, x: inside.x, y: inside.y)
        return AX.frame(of: window) ?? placed
    }

    /// Keeps where the window was before a run of layouts: a window still where the last layout put it keeps the
    /// frame from before that run, so Restore undoes all of it. Restore forgets it.
    private static func remember(_ front: FrontWindow, target: LauncherWindowRect, restoring: Bool) {
        if restoring {
            remembered[front.key] = nil
            rememberedOrder.removeAll { $0 == front.key }
            return
        }
        if let saved = remembered[front.key], isSame(saved.placed, front.frame) {
            remembered[front.key]?.placed = target
            return
        }
        remembered[front.key] = Remembered(before: front.frame, placed: target)
        rememberedOrder.removeAll { $0 == front.key }
        rememberedOrder.append(front.key)
        if rememberedOrder.count > rememberedLimit {
            remembered[rememberedOrder.removeFirst()] = nil
        }
    }

    /// Frames within a couple of points: apps round sizes to their own steps (a terminal's character cells).
    private static func isSame(_ a: LauncherWindowRect, _ b: LauncherWindowRect) -> Bool {
        abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}

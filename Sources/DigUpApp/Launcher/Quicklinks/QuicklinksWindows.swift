import AppKit
import SwiftUI

/// A small window of the feature's own (the quicklink editor, the hotkey recorder), floating in front of everything.
/// Esc or its close button closes it, and then `onClose` runs.
final class QuicklinksWindow: NSObject, NSWindowDelegate {
    /// Kept alive while they're up.
    private static var open: [QuicklinksWindow] = []

    private let window: QuicklinksPanel
    private var onClose: (() -> Void)?

    /// Shows `content` (given a way to close the window) titled `title`. One window per `key`: asking again brings the
    /// open one forward.
    @discardableResult
    static func show<Content: View>(key: String, title: String,
                                    content: (_ close: @escaping () -> Void) -> Content,
                                    onClose: @escaping () -> Void) -> QuicklinksWindow {
        if let existing = open.first(where: { $0.key == key }) {
            existing.window.makeKeyAndOrderFront(nil)
            bringAppToFront()
            return existing
        }
        let shown = QuicklinksWindow(key: key, title: title)
        shown.onClose = onClose
        let hosting = NSHostingController(rootView: AnyView(content { [weak shown] in shown?.close() }))
        hosting.sizingOptions = [.preferredContentSize]
        shown.window.contentViewController = hosting
        shown.window.center()
        open.append(shown)
        bringAppToFront()
        shown.window.makeKeyAndOrderFront(nil)
        return shown
    }

    private let key: String

    private init(key: String, title: String) {
        self.key = key
        window = QuicklinksPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                                 styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
        let done = onClose
        onClose = nil
        // After the window is gone, so whatever comes next can take the keyboard.
        DispatchQueue.main.async { done?() }
    }
}

/// Esc closes it, like a sheet.
private final class QuicklinksPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Alerts for where there's no panel to ask from (Settings, links, imports).
enum QuicklinksAlert {
    /// A message with an OK button.
    static func inform(_ message: String, detail: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        bringAppToFront()
        alert.runModal()
    }

    /// A yes/no question; true for yes.
    static func confirm(_ title: String, message: String = "", button: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let yes = alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        yes.hasDestructiveAction = destructive
        bringAppToFront()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// When nothing of DigUp's is left on screen, the app you were in gets the keyboard back.
    static func returnFocus(to app: NSRunningApplication?) {
        let showing = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeKey && !(window is NSPanel) && window.level == .normal
        }
        guard !showing else { return }
        if let app, app != NSRunningApplication.current {
            app.activate()
        } else {
            NSApp.hide(nil)
        }
    }
}

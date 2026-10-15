import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DigUpKit

/// What an action or a mode can do with the panel and the Mac: hide, push a mode, copy, paste into the app you came
/// from, ask a question.
final class LauncherContext {
    private unowned let panel: SearchPanelController

    init(panel: SearchPanelController) {
        self.panel = panel
    }

    var launcher: Launcher { panel.launcher }
    var app: AppController { panel.appController }

    /// The app that was in front when the panel opened (where paste goes, what window commands act on).
    var previousApp: NSRunningApplication? { panel.previousApp }

    /// What's in the field.
    var query: String {
        get { panel.query }
        set { panel.query = newValue }
    }

    var isPanelVisible: Bool { panel.isVisible }

    /// The id of the selected row, when it's a launcher item.
    var selectedItemID: String? { panel.selectedItem?.id }

    /// Hides the panel and gives the keyboard back to the app you came from.
    func hide() {
        panel.dismissForAction()
    }

    /// Shows the panel again (after an action that hid it).
    func show() {
        panel.show()
    }

    /// Opens a mode over the root search (Clipboard History, Quick AI…), with `query` in the field.
    func push(_ mode: any LauncherMode, query: String = "") {
        if !panel.isVisible { panel.show() }
        panel.push(mode, query: query)
    }

    /// Back to the root search.
    func popToRoot() {
        panel.popToRoot()
    }

    /// Searches again with what's typed (after the list changed: an entry deleted, pinned…).
    func refresh() {
        panel.refresh()
    }

    /// A short message in the panel's footer.
    func flash(_ text: String) {
        panel.flashNote(text)
    }

    /// Puts text on the clipboard.
    func copy(_ text: String, flash message: String? = "Copied to Clipboard") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let message, panel.isVisible { flash(message) }
    }

    /// Hides the panel, then pastes `text` into the app you came from (⌘V, which needs Accessibility; without it, the
    /// text is left on the clipboard and macOS is asked once for the permission).
    func paste(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pasteClipboard()
    }

    /// Pastes whatever is on the clipboard now into the app you came from.
    func pasteClipboard() {
        let target = previousApp
        if panel.isVisible { hide() }
        Task {
            target?.activate()
            try? await Task.sleep(for: .milliseconds(120))
            guard Accessibility.isTrusted(prompt: true) else {
                log("paste: no Accessibility permission; left on the clipboard")
                return
            }
            Keystrokes.post(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// A yes/no question in front of everything ("Empty the Trash?"). True for yes.
    func confirm(_ title: String, message: String = "", button: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let yes = alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if destructive { yes.hasDestructiveAction = true }
        bringAppToFront()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks for one line of text ("Alias for Safari"); nil when cancelled.
    func prompt(_ title: String, message: String = "", initial: String = "", button: String = "Save") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        bringAppToFront()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

/// The Accessibility permission (System Settings → Privacy & Security → Accessibility): pasting, window commands,
/// selected text and menu items need it.
enum Accessibility {
    /// Whether DigUp has it. With `prompt`, macOS shows its dialog once if not.
    @discardableResult
    static func isTrusted(prompt: Bool = false) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// Synthetic key presses (paste, text expansion).
enum Keystrokes {
    static func post(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

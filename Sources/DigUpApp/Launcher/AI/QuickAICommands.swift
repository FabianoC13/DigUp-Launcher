import AppKit
import ApplicationServices
import DigUpKit

/// Running an AI Command (Fix Spelling and Grammar, Summarize…): reads the text selected in the app you came from
/// (through Accessibility), or the clipboard's when that isn't possible, and asks it in a new Quick AI chat with the
/// command's instructions as the system prompt. Rewrites paste back over the selection on ↩. Without a command (Ask AI
/// About Selected Text) the text waits in a plain chat for your question about it.
enum QuickAICommands {
    /// Texts longer than this are cut (a whole document selected by accident shouldn't cost a fortune).
    static let characterLimit = 100_000

    /// What reading the selection found.
    enum Selection: Sendable {
        case text(String)
        /// DigUp isn't allowed in Privacy & Security → Accessibility.
        case noPermission
        /// Nothing selected, or the app doesn't share its selection.
        case none
    }

    static func run(_ command: AICommand?, context: LauncherContext, fromClipboard: Bool = false) {
        guard QuickAIFeature.isSetUp else {
            context.push(QuickAISetupMode(prompt: ""))
            return
        }
        let chat = QuickAIChat.shared
        chat.context = context
        chat.startNew(command: command)
        let app = context.previousApp
        let appName = app?.localizedName ?? "the app"
        chat.notice = fromClipboard ? "Reading the clipboard…" : "Reading the text selected in \(appName)…"
        context.push(QuickAIMode(chat: chat))
        let chatID = chat.id
        let again = command.map { "run \($0.title) again" } ?? "ask again"
        Task {
            var selection = Selection.none
            if !fromClipboard, let pid = app?.processIdentifier {
                selection = await Task.detached { selectedText(pid: pid) }.value
            }
            // You may have left, or started something else, while it was being read.
            guard chat.id == chatID, chat.turns.isEmpty else { return }
            let clipboard = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var text: String
            var source: String
            switch selection {
            case .text(let selected):
                text = selected
                source = "selected in \(appName)"
            case .noPermission where !clipboard.isEmpty:
                text = clipboard
                source = "clipboard"
                context.flash("Used the clipboard: reading the selection needs Accessibility permission")
            case .none where !clipboard.isEmpty:
                text = clipboard
                source = "clipboard"
                if !fromClipboard { context.flash("No text selected in \(appName): used the clipboard") }
            case .noPermission:
                chat.notice = "Quick AI reads the selected text through Accessibility, which DigUp isn't allowed "
                    + "yet. Allow it in System Settings → Privacy & Security → Accessibility, or copy the text and "
                    + "\(again)."
                Accessibility.isTrusted(prompt: true)
                return
            case .none:
                chat.notice = fromClipboard
                    ? "There's no text on the clipboard. Copy some, then \(again)."
                    : "Select some text in \(appName) (or copy it), then \(again)."
                return
            }
            if text.count > characterLimit {
                text = String(text.prefix(characterLimit))
                context.flash("The text was cut to its first \(characterLimit.formatted()) characters")
            }
            let origin = source == "clipboard" ? "clipboard" : "selection"
            guard let command else {
                chat.attach(text, source: source == "clipboard" ? "from the clipboard" : source)
                let preview = text.count > 280 ? text.prefix(280) + "…" : text
                chat.notice = "Ask anything about the \(text.count.formatted()) characters "
                    + (source == "clipboard" ? "on the clipboard" : source) + ":\n“\(preview)”"
                log("quick ai: asking about \(text.count) characters (\(origin))")
                return
            }
            chat.startNew(command: command, source: source)
            chat.ask(command.message(for: text), shown: text, original: command.replacesSelection ? text : nil)
            log("quick ai: \(command.rawValue) on \(text.count) characters (\(origin))")
        }
    }

    /// The text selected in the app with this process id: its focused element's AXSelectedText. Off the main thread
    /// (an app that's busy can take its time answering; each question waits a second at most).
    nonisolated static func selectedText(pid: pid_t) -> Selection {
        guard AXIsProcessTrusted() else { return .noPermission }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var focused: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        if status != .success {
            // Chromium and Electron apps build their accessibility tree only once something asks for it.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        }
        guard status == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .none }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        return .text(text)
    }
}

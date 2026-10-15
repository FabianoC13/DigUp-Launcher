import AppKit
import DigUpKit
import SwiftUI

/// Quick AI: type a question, press Tab, and the answer streams in from your API (DeepSeek by default; OpenAI,
/// Anthropic, OpenRouter, Gemini, Ollama or any OpenAI-compatible server in Settings). Also the AI Commands on the
/// selected text, and the history of past chats.
enum QuickAIFeature: LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [QuickAIProvider()]
    }

    static func start(_ launcher: Launcher) {
        Task { await QuickAIHistory.shared.load() }
        QuickAIFirstRun.askIfNeeded(launcher)
    }

    static var settingsTitle: String? { "Quick AI" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(QuickAISettingsView())
    }

    /// Tab in the root search: asks `prompt` (or opens Quick AI empty). The chat carries on from the last one unless it
    /// has been idle past Settings' "new chat" time; without a key, a page says where to add one.
    static func ask(_ prompt: String, context: LauncherContext) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSetUp else {
            context.push(QuickAISetupMode(prompt: prompt))
            return
        }
        let chat = QuickAIChat.shared
        chat.context = context
        chat.prepareForOpening()
        context.push(QuickAIMode(chat: chat))
        if !prompt.isEmpty { chat.ask(prompt) }
        Task { await QuickAIHistory.shared.load() }
    }

    /// Drop or paste of images onto the panel: open Quick AI if needed, then queue them for the next question (never
    /// insert the file path as text).
    static func attachImages(_ images: [QuickAIPendingImage], context: LauncherContext) {
        guard !images.isEmpty else { return }
        guard isSetUp else {
            context.push(QuickAISetupMode(prompt: ""))
            context.flash("Add an API key before attaching images")
            return
        }
        let chat = QuickAIChat.shared
        chat.context = context
        if !(context.mode is QuickAIMode) {
            chat.prepareForOpening()
            context.push(QuickAIMode(chat: chat))
        }
        chat.attachImages(images)
        let label = images.count == 1 ? "Attached \(images[0].name)" : "Attached \(images.count) images"
        context.flash(label)
        context.refresh()
        Task { await QuickAIHistory.shared.load() }
    }

    /// A fresh chat, whatever the timeout says (the "New AI Chat" command).
    static func newChat(context: LauncherContext) {
        guard isSetUp else {
            context.push(QuickAISetupMode(prompt: ""))
            return
        }
        let chat = QuickAIChat.shared
        chat.context = context
        chat.startNew()
        context.push(QuickAIMode(chat: chat))
    }

    /// Whether questions can be sent: a key saved for the provider (read from its Keychain attributes only, so no
    /// prompt), or a base URL for the providers that need no key.
    static var isSetUp: Bool {
        let preferences = QuickAIPreferences.shared
        let preset = preferences.provider
        if preset.keyOptional { return !preferences.baseURL(for: preset).isEmpty }
        return QuickAIKeys.shared.exists(preset.id)
    }

    /// Settings → Launcher, where the Quick AI section is.
    static func openSettings(_ context: LauncherContext?) {
        guard let context else { return }
        if context.isPanelVisible { context.hide() }
        context.app.showSettings(.launcher)
    }
}

/// The root commands: Quick AI, New AI Chat, AI Chat History, and one per AI Command (Fix Spelling and Grammar…).
final class QuickAIProvider: LauncherProvider {
    let id = "ai"

    private static let commandPrefix = "ai:cmd:"

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        var items: [LauncherItem] = []
        for (base, keywords) in Self.baseItems {
            if let score = query.match(base.title, keywords: keywords) { items.append(scored(base, score)) }
        }
        for command in AICommand.allCases {
            if let score = query.match(command.title, keywords: command.keywords) {
                items.append(scored(Self.item(command), score))
            }
        }
        if let score = query.match("AI Credits", keywords: ["credits", "balance", "usage", "deepseek balance"]) {
            await QuickAICredits.shared.loaded()
            items.append(scored(Self.creditsItem(), score))
        }
        return items
    }

    /// "AI Credits: 99%": what's left of the API credit, with the bar in the preview.
    private static func creditsItem() -> LauncherItem {
        let credits = QuickAICredits.shared
        credits.refresh()
        let title: String
        let subtitle: String
        switch credits.state {
        case .loaded(let value, _):
            title = "AI Credits: \(value.percentText) left"
            subtitle = "\(value.amountText) · \(providerName)"
        case .unsupported:
            title = "AI Credits"
            subtitle = "\(providerName) doesn't say how much credit is left"
        case .failed(let message):
            title = "AI Credits"
            subtitle = message
        case .unknown:
            title = "AI Credits"
            subtitle = "Checking \(providerName)…"
        }
        return LauncherItem(
            id: "ai:credits", title: title, subtitle: subtitle, icon: .symbol("gauge.with.dots.needle.50percent"),
            accessory: "Quick AI",
            actions: [LauncherAction(id: "refresh", title: "Check Again", symbol: "arrow.clockwise",
                                     keepsPanelOpen: true) { context in
                QuickAICredits.shared.refresh(force: true)
                try? await Task.sleep(for: .seconds(1.5))
                context.refresh()
            }],
            detail: .custom(AnyView(VStack(spacing: 14) {
                Spacer(minLength: 40)
                QuickAICreditsBar()
                Text("DeepSeek only says the balance: 100% is the amount you topped up, guessed from it until you set it "
                     + "in Settings → Launcher → Quick AI.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }.frame(maxWidth: .infinity))))
    }

    func item(id: String) async -> LauncherItem? {
        if id == "ai:credits" { return Self.creditsItem() }
        if let base = Self.baseItems.first(where: { $0.item.id == id }) { return base.item }
        guard id.hasPrefix(Self.commandPrefix),
              let command = AICommand(rawValue: String(id.dropFirst(Self.commandPrefix.count))) else { return nil }
        return Self.item(command)
    }

    private func scored(_ item: LauncherItem, _ score: Double) -> LauncherItem {
        var item = item
        item.score = score
        return item
    }

    private static var providerName: String { QuickAIPreferences.shared.provider.name }

    private static var baseItems: [(item: LauncherItem, keywords: [String])] {
        let settings = LauncherAction(id: "settings", title: "Quick AI Settings…", symbol: "gearshape",
                                      shortcut: LauncherShortcut(",", .command)) { context in
            QuickAIFeature.openSettings(context)
        }
        let quick = LauncherItem(
            id: "ai:quick", title: "Quick AI", subtitle: "Ask \(providerName) anything",
            icon: .symbol("sparkles", Brand.leaf), accessory: "Command",
            actions: [LauncherAction(id: "open", title: "Open Quick AI", symbol: "sparkles", keepsPanelOpen: true) {
                QuickAIFeature.ask("", context: $0)
            }, settings],
            detail: .markdown("**Quick AI** answers in the launcher, streaming as Markdown.\n\n"
                + "Tip: type a question in the search field and press **Tab** to ask it straight away. ↩ with an "
                + "empty field pastes the answer into the app you came from."))
        let new = LauncherItem(
            id: "ai:new", title: "New AI Chat", subtitle: "Start a fresh Quick AI conversation",
            icon: .symbol("square.and.pencil", Brand.leaf), accessory: "Command",
            actions: [LauncherAction(id: "open", title: "Start New Chat", symbol: "square.and.pencil",
                                     keepsPanelOpen: true) { QuickAIFeature.newChat(context: $0) }, settings])
        let history = LauncherItem(
            id: "ai:history", title: "AI Chat History", subtitle: "Reopen or delete past Quick AI chats",
            icon: .symbol("clock.arrow.circlepath", Brand.leaf), accessory: "Command",
            actions: [LauncherAction(id: "open", title: "Open AI Chat History", symbol: "clock.arrow.circlepath",
                                     keepsPanelOpen: true) { $0.push(QuickAIHistoryMode()) }, settings])
        let about = LauncherItem(
            id: "ai:ask-selection", title: "Ask AI About Selected Text",
            subtitle: "Ask Quick AI a question about the text selected in the app you came from",
            icon: .symbol("text.bubble", Brand.leaf), accessory: "Command",
            actions: [LauncherAction(id: "open", title: "Ask About Selected Text", symbol: "text.bubble",
                                     keepsPanelOpen: true) { QuickAICommands.run(nil, context: $0) },
                      LauncherAction(id: "clipboard", title: "Ask About Clipboard Text", symbol: "doc.on.clipboard",
                                     keepsPanelOpen: true) { QuickAICommands.run(nil, context: $0, fromClipboard: true) }],
            detail: .markdown("**Ask AI About Selected Text**\n\nSelect text in any app, open the launcher and run "
                + "this, then type your question about it. Without Accessibility permission (or when the app doesn't "
                + "share its selection), the text on the clipboard is used instead."))
        return [
            (quick, ["ai", "ask", "chat", "question", "deepseek", "gpt", "llm", "assistant"]),
            (about, ["ai", "ask", "selection", "selected", "text", "context", "question"]),
            (new, ["ai", "chat", "conversation", "new", "fresh"]),
            (history, ["ai", "chats", "conversations", "past", "previous", "history"]),
        ]
    }

    static func item(_ command: AICommand) -> LauncherItem {
        let output = command.replacesSelection
            ? "↩ pastes the result over the selection; ⌘↩ copies it."
            : "The answer opens in Quick AI, where you can ask follow-ups."
        return LauncherItem(
            id: commandPrefix + command.rawValue, title: command.title, subtitle: command.subtitle,
            icon: .symbol(command.symbol, Brand.leaf), accessory: "AI Command",
            actions: [
                LauncherAction(id: "run", title: "Run on Selected Text", symbol: command.symbol, keepsPanelOpen: true) {
                    QuickAICommands.run(command, context: $0)
                },
                LauncherAction(id: "clipboard", title: "Run on Clipboard Text", symbol: "doc.on.clipboard",
                               keepsPanelOpen: true) {
                    QuickAICommands.run(command, context: $0, fromClipboard: true)
                },
            ],
            detail: .markdown("**\(command.title)**\n\n\(command.subtitle)\n\nSelect text in any app, open the "
                + "launcher and run this. Without Accessibility permission (or when the app doesn't share its "
                + "selection), the text on the clipboard is used instead.\n\n\(output)"))
    }
}

/// `-debugQuickAI YES`: logs how each answer ended (phase, model, length and its first words), for checking Quick AI
/// end to end in a dev run with `-debugQuery` and `-debugKeys tab`.
enum QuickAIDebug {
    static let enabled = UserDefaults.standard.bool(forKey: "debugQuickAI")

    static func answered(_ chat: QuickAIChat) {
        guard enabled, let turn = chat.lastTurn else { return }
        let start = turn.answer.prefix(160).replacingOccurrences(of: "\n", with: " ")
        log("debug: quick ai \(turn.phase) · \(turn.model) · \(turn.answer.count) characters · "
            + "\(turn.reasoning.count) of reasoning · “\(start)”")
    }
}

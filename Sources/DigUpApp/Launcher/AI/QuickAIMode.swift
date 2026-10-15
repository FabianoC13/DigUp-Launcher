import AppKit
import DigUpKit
import SwiftUI

/// Quick AI in the panel: the conversation, with the field as the follow-up box.
///
/// ↩ sends what's typed; with nothing typed it pastes the last answer into the app you came from (or copies it, per
/// Settings; ⌘↩ does the other). ⌘R regenerates, ⇧⌘R regenerates with the other model, ⌘N starts a new chat, ⌘.
/// stops, ⇧⌘C copies the answer, ⌘[ / ⌘] step through earlier chats, ↑↓ scroll. ⌘K lists all of it.
final class QuickAIMode: LauncherMode {
    let chat: QuickAIChat
    let scroller = QuickAIScroller()
    private weak var context: LauncherContext?
    private var preferences: QuickAIPreferences { .shared }

    init(chat: QuickAIChat) {
        self.chat = chat
    }

    var title: String { chat.command?.title ?? "Quick AI" }
    var placeholder: String { chat.turns.isEmpty ? "Ask anything…" : "Ask a follow-up…" }
    var icon: LauncherIcon { .symbol(chat.command?.symbol ?? "sparkles") }

    /// One invisible row whose actions are the chat's, so ⌘K lists them (the view replaces the list).
    func items(for query: LauncherQuery) async -> [LauncherItem] {
        [LauncherItem(id: "ai:conversation", title: title, icon: icon, section: .named("Chat", order: 0),
                      actions: actions(), tracksUsage: false)]
    }

    func makeView(context: LauncherContext) -> AnyView? {
        self.context = context
        chat.context = context
        let actions = QuickAIViewActions(
            copy: { [weak context] text, message in context?.copy(text, flash: message) },
            retry: { [weak self] in self?.regenerate() },
            openSettings: { [weak context] in QuickAIFeature.openSettings(context) })
        return AnyView(QuickAIConversationView(chat: chat, scroller: scroller, actions: actions))
    }

    func didClose() {
        chat.closed()
    }

    // MARK: Keys

    func handle(_ event: NSEvent, query: String, context: LauncherContext) -> Bool {
        self.context = context
        chat.context = context
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, flags.isEmpty {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                deliver(primary: true)
            } else {
                send(text)
            }
            return true
        }
        if isReturn, flags == .command {
            deliver(primary: false)
            return true
        }
        // ⌘C copies the answer straight away, unless part of the follow-up you're typing is selected (then that text,
        // as anywhere).
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c",
           ((NSApp.keyWindow?.firstResponder as? NSTextView)?.selectedRange().length ?? 0) == 0 {
            if chat.isBusy {
                context.flash("Still answering: ⌘C copies it once it's done")
            } else {
                copyAnswer(close: false)
            }
            return true
        }
        switch event.keyCode {
        case 125 where flags.isEmpty, 126 where flags.isEmpty:   // ↓ ↑ scroll the conversation
            scroller.scroll(by: event.keyCode == 125 ? 56 : -56)
            return true
        case 125 where flags == .command:
            scroller.scrollToBottom()
            return true
        case 126 where flags == .command:
            scroller.scrollToTop()
            return true
        case 121, 116:   // page down, page up
            scroller.page(event.keyCode == 121 ? 1 : -1)
            return true
        default:
            break
        }
        let keys: [(LauncherShortcut, () -> Void)] = [
            (Self.regenerateKey, { [self] in regenerate() }),
            (Self.regenerateOtherKey, { [self] in regenerateWithOtherModel() }),
            (Self.newChatKey, { [self] in newChat() }),
            (Self.stopKey, { [self] in stop() }),
            (Self.copyKey, { [self] in copyAnswer(close: false) }),
            (Self.previousKey, { [self] in step(older: true) }),
            (Self.nextKey, { [self] in step(older: false) }),
            (Self.changesKey, { [self] in toggleChanges() }),
        ]
        for (shortcut, run) in keys where shortcut.matches(event) {
            run()
            return true
        }
        return false
    }

    static let regenerateKey = LauncherShortcut("r", .command)
    static let regenerateOtherKey = LauncherShortcut("r", [.command, .shift])
    static let newChatKey = LauncherShortcut("n", .command)
    static let stopKey = LauncherShortcut(".", .command)
    static let copyKey = LauncherShortcut.copyShift
    static let previousKey = LauncherShortcut("[", .command)
    static let nextKey = LauncherShortcut("]", .command)
    static let changesKey = LauncherShortcut("d", .command)

    var keysHint: String? {
        let typed = !(context?.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if typed { return chat.turns.isEmpty ? "↩ Ask   ⌘K Actions" : "↩ Send Follow-up   ⌘K Actions" }
        if chat.isBusy { return "⌘. Stop   ↑↓ Scroll   ⌘K Actions   Esc Back" }
        if chat.lastTurn?.failure != nil { return "⌘R Retry   ⌘N New Chat   ⌘K Actions" }
        guard chat.lastAnswer != nil else { return "↩ Ask   ⌘K Actions   Esc Back" }
        let paste = primaryIsPaste ? "↩ Paste" : "⌘↩ Paste"
        return "⌘C Copy   \(paste)   ⌘R Regenerate   ⌘N New Chat   ⌘K Actions"
    }

    var statusHint: String? {
        let model = preferences.displayName(chat.lastTurn?.model ?? chat.model)
        guard let turn = chat.lastTurn else { return "\(preferences.provider.name) · \(model)" }
        switch turn.phase {
        case .readingKey: return "\(model) · reading the key from the Keychain…"
        case .waiting: return "\(model) · waiting…"
        case .thinking: return "\(model) · thinking…"
        case .answering: return "\(model) · answering…"
        case .stopped: return "\(model) · stopped"
        case .failed: return "\(model) · failed"
        case .done:
            let count = chat.turns.count
            return count == 1 ? model : "\(model) · \(count) questions"
        }
    }

    // MARK: Doing

    /// Rewrites go back where the text came from; otherwise the setting decides.
    private var primaryIsPaste: Bool {
        chat.command?.replacesSelection == true || preferences.primaryAction == .paste
    }

    private func send(_ text: String) {
        context?.query = ""
        chat.ask(text)
        scroller.resume()
    }

    /// The answer to hand over: a rewrite without the wrapping a model may add.
    private var answerText: String? {
        guard let answer = chat.lastAnswer else { return nil }
        return chat.command?.replacesSelection == true ? AICommand.cleanRewrite(answer) : answer
    }

    /// ↩ / ⌘↩ with nothing typed: the last answer pasted or copied.
    private func deliver(primary: Bool) {
        guard let context else { return }
        if chat.isBusy {
            context.flash("Still answering: ⌘. stops it")
            return
        }
        guard let answer = answerText else {
            context.flash(chat.turns.isEmpty ? "Type a question first" : "There's no answer to use yet")
            return
        }
        if primary == primaryIsPaste {
            paste(answer, context: context)
        } else {
            context.copy(answer, flash: nil)
            context.hide()
        }
    }

    private func paste(_ answer: String, context: LauncherContext) {
        // Without Accessibility ⌘V can't be sent: copy instead, say so, and let macOS ask for the permission.
        guard Accessibility.isTrusted() else {
            context.copy(answer, flash: "Copied. To paste, allow DigUp in Privacy & Security → Accessibility")
            Accessibility.isTrusted(prompt: true)
            return
        }
        context.paste(answer)
    }

    private func copyAnswer(close: Bool) {
        guard let context else { return }
        guard let answer = answerText else {
            context.flash("There's no answer to copy yet")
            return
        }
        context.copy(answer, flash: close ? nil : "Copied the answer")
        if close { context.hide() }
    }

    private func regenerate() {
        guard chat.lastTurn != nil else {
            context?.flash("Nothing to regenerate yet")
            return
        }
        chat.regenerate()
        scroller.resume()
    }

    private func regenerateWithOtherModel() {
        guard let model = otherModel else {
            context?.flash("There's no other model for \(preferences.provider.name): pick one in Settings")
            return
        }
        regenerate(with: model)
    }

    private func regenerate(with model: String) {
        guard chat.lastTurn != nil else {
            context?.flash("Nothing to regenerate yet")
            return
        }
        chat.regenerate(model: model)
        scroller.resume()
        context?.refresh()   // the actions name the models
    }

    private var otherModel: String? {
        let preset = preferences.provider
        return preset.otherModel(than: chat.model, available: preferences.modelChoices(for: preset))
    }

    private func stop() {
        guard chat.isBusy else {
            context?.flash("Nothing to stop")
            return
        }
        chat.stop()
    }

    private func newChat() {
        chat.startNew()
        context?.query = ""
        context?.refresh()
        context?.flash("New chat")
    }

    /// ⌘[ (older) and ⌘] (newer): the chats in the history, in order.
    private func step(older: Bool) {
        let chats = QuickAIHistory.shared.chats
        let index = chats.firstIndex { $0.id == chat.id }
        let target: Int
        if let index {
            target = older ? index + 1 : index - 1
        } else {
            target = older ? 0 : -1   // a chat that isn't saved yet is the newest
        }
        guard chats.indices.contains(target) else {
            context?.flash(older ? "No older chats" : "This is the newest chat")
            return
        }
        chat.open(chats[target])
        context?.query = ""
        context?.refresh()
        DispatchQueue.main.async { [scroller] in scroller.scrollToBottom() }
    }

    private func toggleChanges() {
        guard let turn = chat.turns.last(where: { $0.original != nil && $0.phase == .done }) else {
            context?.flash("Show Changes is for rewrites (Fix Spelling, Improve Writing…)")
            return
        }
        turn.showsChanges.toggle()
    }

    // MARK: Actions (⌘K)

    private func actions() -> [LauncherAction] {
        let paste = LauncherAction(id: "paste", title: "Paste Answer", symbol: "doc.on.clipboard",
                                   keepsPanelOpen: true) { [weak self] _ in self?.deliver(primary: self?.primaryIsPaste ?? true) }
        let copy = LauncherAction(id: "copy", title: "Copy Answer and Close", symbol: "doc.on.doc",
                                  keepsPanelOpen: true) { [weak self] _ in self?.copyAnswer(close: true) }
        var actions = primaryIsPaste ? [paste, copy] : [copy, paste]
        actions.append(LauncherAction(id: "copy-stay", title: "Copy Answer", symbol: "doc.on.doc",
                                      shortcut: Self.copyKey, keepsPanelOpen: true) { [weak self] _ in
            self?.copyAnswer(close: false)
        })
        actions.append(LauncherAction(id: "copy-chat", title: "Copy Chat as Markdown", symbol: "text.quote",
                                      shortcut: LauncherShortcut("c", [.command, .option, .shift]),
                                      keepsPanelOpen: true) { [weak self] context in
            guard let self, !chat.turns.isEmpty else { return }
            context.copy(chat.record.markdown, flash: "Copied the chat")
        })
        actions.append(LauncherAction(id: "regenerate", title: "Regenerate", symbol: "arrow.clockwise",
                                      shortcut: Self.regenerateKey, keepsPanelOpen: true) { [weak self] _ in
            self?.regenerate()
        })
        let preset = preferences.provider
        let others = preferences.modelChoices(for: preset).filter { $0 != chat.model }
        if let other = otherModel {
            actions.append(LauncherAction(id: "regenerate-other", title: "Regenerate with \(preferences.displayName(other))",
                                          symbol: "arrow.triangle.2.circlepath", shortcut: Self.regenerateOtherKey,
                                          keepsPanelOpen: true) { [weak self] _ in self?.regenerate(with: other) })
        }
        for model in others.prefix(6) where model != otherModel {
            actions.append(LauncherAction(id: "regenerate-\(model)", title: "Regenerate with \(preferences.displayName(model))",
                                          symbol: "cpu", keepsPanelOpen: true) { [weak self] _ in
                self?.regenerate(with: model)
            })
        }
        if chat.turns.contains(where: { $0.original != nil }) {
            actions.append(LauncherAction(id: "changes", title: "Show or Hide Changes", symbol: "text.badge.checkmark",
                                          shortcut: Self.changesKey, keepsPanelOpen: true) { [weak self] _ in
                self?.toggleChanges()
            })
        }
        actions.append(LauncherAction(id: "stop", title: "Stop Answering", symbol: "stop.circle",
                                      shortcut: Self.stopKey, keepsPanelOpen: true) { [weak self] _ in self?.stop() })
        actions.append(LauncherAction(id: "new", title: "New Chat", symbol: "square.and.pencil",
                                      shortcut: Self.newChatKey, keepsPanelOpen: true) { [weak self] _ in
            self?.newChat()
        })
        actions.append(LauncherAction(id: "older", title: "Previous Chat", symbol: "chevron.backward",
                                      shortcut: Self.previousKey, keepsPanelOpen: true) { [weak self] _ in
            self?.step(older: true)
        })
        actions.append(LauncherAction(id: "newer", title: "Next Chat", symbol: "chevron.forward",
                                      shortcut: Self.nextKey, keepsPanelOpen: true) { [weak self] _ in
            self?.step(older: false)
        })
        actions.append(LauncherAction(id: "history", title: "AI Chat History", symbol: "clock.arrow.circlepath",
                                      shortcut: LauncherShortcut("h", [.command, .shift]),
                                      keepsPanelOpen: true) { context in
            context.push(QuickAIHistoryMode())
        })
        actions.append(LauncherAction(id: "settings", title: "Quick AI Settings…", symbol: "gearshape",
                                      shortcut: LauncherShortcut(",", .command)) { context in
            QuickAIFeature.openSettings(context)
        })
        return actions
    }
}

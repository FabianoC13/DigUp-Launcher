import AppKit
import DigUpKit
import SwiftUI

/// AI Chat History: the saved Quick AI chats, newest first, grouped by day. ↩ reopens one (to read, or to carry on
/// with a follow-up), ⇧⌘C copies it as Markdown, ⌃X deletes it.
final class QuickAIHistoryMode: LauncherMode {
    var title: String { "AI Chat History" }
    var placeholder: String { "Search chats…" }
    var icon: LauncherIcon { .symbol("clock.arrow.circlepath") }

    var statusHint: String? {
        let count = QuickAIHistory.shared.chats.count
        return count == 1 ? "1 chat" : "\(count) chats"
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let history = QuickAIHistory.shared
        await history.load()
        guard !history.chats.isEmpty else {
            return [LauncherItem(
                id: "ai:history-empty", title: "No Saved Chats Yet", subtitle: "Ask Quick AI something to start one",
                icon: .symbol("sparkles", Brand.leaf), section: .named("Chats", order: 0),
                actions: [LauncherAction(id: "new", title: "Open Quick AI", symbol: "sparkles", keepsPanelOpen: true) {
                    QuickAIFeature.ask("", context: $0)
                }], tracksUsage: false)]
        }
        var items: [LauncherItem] = []
        let now = Date()
        for (index, chat) in history.chats.enumerated() {
            // Newest first while nothing is typed; by how well the title matches otherwise, any word of the chat
            // counting a little.
            var score = 1 - Double(index) / 1000
            if !query.isEmpty {
                if let match = query.match(chat.title, keywords: chat.turns.map(\.question)) {
                    score = 0.5 + match / 2
                } else if chat.markdown.range(of: query.text, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    score = 0.3
                } else {
                    continue
                }
            }
            items.append(item(chat, score: score, now: now))
        }
        return items
    }

    private func item(_ chat: AIChatRecord, score: Double, now: Date) -> LauncherItem {
        let command = chat.command.flatMap(AICommand.init(rawValue:))
        let questions = chat.turns.count == 1 ? "1 question" : "\(chat.turns.count) questions"
        let model = chat.turns.last.map { QuickAIPreferences.shared.displayName($0.model) } ?? ""
        let (section, order) = Self.day(chat.updated, now: now)
        return LauncherItem(
            id: "ai:chat:\(chat.id.uuidString)", title: chat.title,
            subtitle: "\(questions) · \(AIProviderPreset.named(chat.provider).name)",
            icon: .symbol(command?.symbol ?? "bubble.left.and.text.bubble.right", Brand.leaf),
            accessory: chat.updated.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)),
            section: .named(section, order: order), score: score,
            actions: actions(chat),
            detail: .markdown(chat.markdown),
            metadata: [("Model", model), ("Started", chat.created.formatted(date: .abbreviated, time: .shortened)),
                       ("Updated", chat.updated.formatted(date: .abbreviated, time: .shortened))],
            tracksUsage: false)
    }

    private func actions(_ chat: AIChatRecord) -> [LauncherAction] {
        [
            LauncherAction(id: "open", title: "Open Chat", symbol: "bubble.left.and.text.bubble.right",
                           keepsPanelOpen: true) { context in
                let current = QuickAIChat.shared
                current.context = context
                current.open(chat)
                context.push(QuickAIMode(chat: current))
            },
            LauncherAction(id: "copy-answer", title: "Copy Last Answer", symbol: "doc.on.doc",
                           shortcut: .copy) { context in
                guard let answer = chat.lastAnswer, !answer.isEmpty else { return }
                context.copy(answer, flash: nil)
            },
            LauncherAction(id: "copy-chat", title: "Copy Chat as Markdown", symbol: "text.quote",
                           shortcut: .copyShift) { context in
                context.copy(chat.markdown, flash: nil)
            },
            LauncherAction(id: "delete", title: "Delete Chat", symbol: "trash", shortcut: .deleteItem,
                           style: .destructive, keepsPanelOpen: true) { context in
                guard context.confirm("Delete “\(chat.title)”?", message: "The chat is removed from the history.",
                                      button: "Delete", destructive: true) else { return }
                QuickAIChat.shared.forget(chat.id)
                QuickAIHistory.shared.delete(chat.id)
                context.refresh()
            },
            LauncherAction(id: "delete-all", title: "Delete All Chats…", symbol: "trash.slash",
                           shortcut: LauncherShortcut("x", [.control, .shift]), style: .destructive,
                           keepsPanelOpen: true) { context in
                let count = QuickAIHistory.shared.chats.count
                guard context.confirm("Delete all \(count) saved chats?", message: "This can't be undone.",
                                      button: "Delete All", destructive: true) else { return }
                for chat in QuickAIHistory.shared.chats { QuickAIChat.shared.forget(chat.id) }
                QuickAIHistory.shared.removeAll()
                context.refresh()
            },
        ]
    }

    /// "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", then the month ("September 2026").
    private static func day(_ date: Date, now: Date) -> (String, Int) {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return ("Today", 0) }
        if calendar.isDateInYesterday(date) { return ("Yesterday", 1) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return ("Previous 7 Days", 2) }
        if days < 30 { return ("Previous 30 Days", 3) }
        let month = calendar.dateComponents([.year, .month], from: date)
        let months = (calendar.dateComponents([.year, .month], from: now).year ?? 0) * 12
            + (calendar.dateComponents([.month], from: now).month ?? 0)
            - ((month.year ?? 0) * 12 + (month.month ?? 0))
        return (date.formatted(.dateTime.month(.wide).year()), 4 + max(0, months))
    }
}

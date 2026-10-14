import Foundation

/// A Quick AI chat as it's saved: its questions and answers, which provider answered, and when.
public struct AIChatRecord: Codable, Identifiable, Equatable, Sendable {
    public struct Turn: Codable, Equatable, Sendable {
        /// What was sent to the model.
        public var question: String
        /// What the chat showed as the question when it differs (an AI command shows the selected text, and sends it
        /// wrapped in instructions).
        public var shown: String?
        public var answer: String
        /// The model's reasoning, when it showed any.
        public var reasoning: String?
        public var model: String
        public var date: Date

        public init(question: String, shown: String? = nil, answer: String, reasoning: String? = nil, model: String,
                    date: Date) {
            self.question = question
            self.shown = shown
            self.answer = answer
            self.reasoning = reasoning
            self.model = model
            self.date = date
        }
    }

    public var id: UUID
    /// The first question, cut short (`AIChatTitle`).
    public var title: String
    public var created: Date
    public var updated: Date
    /// The provider preset's id ("deepseek").
    public var provider: String
    /// The AI command it was started by ("fix-spelling"), nil for a plain chat.
    public var command: String?
    /// The system prompt it ran with, when it isn't the settings' (an AI command's).
    public var systemPrompt: String?
    public var turns: [Turn]

    public init(id: UUID = UUID(), title: String, created: Date, updated: Date, provider: String,
                command: String? = nil, systemPrompt: String? = nil, turns: [Turn]) {
        self.id = id
        self.title = title
        self.created = created
        self.updated = updated
        self.provider = provider
        self.command = command
        self.systemPrompt = systemPrompt
        self.turns = turns
    }

    /// The last answer, for copying from the history list.
    public var lastAnswer: String? {
        turns.last { !$0.answer.isEmpty }?.answer
    }

    /// The chat as Markdown: each question as a quote, then its answer.
    public var markdown: String {
        turns.map { turn in
            let question = (turn.shown ?? turn.question).split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }.joined(separator: "\n")
            return "\(question)\n\n\(turn.answer)"
        }.joined(separator: "\n\n---\n\n")
    }
}

/// The saved chats, newest first, at most `limit` of them.
public struct AIChatHistory: Codable, Equatable, Sendable {
    public static let limit = 100
    public private(set) var chats: [AIChatRecord] = []

    public init(chats: [AIChatRecord] = []) {
        self.chats = chats
        order()
    }

    private enum CodingKeys: String, CodingKey { case chats }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chats = try container.decodeIfPresent([AIChatRecord].self, forKey: .chats) ?? []
        order()
    }

    /// Adds the chat, or replaces the saved one with its id. Chats without an answer aren't kept.
    public mutating func save(_ chat: AIChatRecord) {
        chats.removeAll { $0.id == chat.id }
        guard chat.turns.contains(where: { !$0.answer.isEmpty }) else { return }
        chats.append(chat)
        order()
    }

    public mutating func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        chats.removeAll()
    }

    public func chat(_ id: UUID) -> AIChatRecord? {
        chats.first { $0.id == id }
    }

    /// Newest first, the oldest past `limit` dropped.
    private mutating func order() {
        chats.sort { $0.updated > $1.updated }
        if chats.count > Self.limit { chats.removeLast(chats.count - Self.limit) }
    }
}

/// A chat's title: its first question on one line, cut at a word near `limit` characters.
public enum AIChatTitle {
    public static func make(_ question: String, limit: Int = 60) -> String {
        let line = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > limit else { return line.isEmpty ? "Untitled Chat" : line }
        let cut = line.prefix(limit)
        if line[cut.endIndex] == " " { return String(cut) + "…" }   // it ends at a word already
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }
}

/// Whether opening Quick AI again continues the last chat or starts a new one.
public enum AIContinuity {
    /// The setting's "never start a new chat by itself".
    public static let never = -1
    /// The setting's "start a new chat every time".
    public static let always = 0

    /// `minutes` is the setting: how long a chat stays open without use (`never`, `always`, or minutes).
    public static func continues(lastActivity: Date, now: Date = Date(), minutes: Int) -> Bool {
        if minutes == never { return true }
        if minutes <= always { return false }
        return now.timeIntervalSince(lastActivity) < Double(minutes) * 60
    }
}

import Foundation

/// One message of a chat, as OpenAI-compatible APIs take it.
public struct AIChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }

    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// The body of `POST /chat/completions`. Optional settings are left out of the JSON when unset, so a provider that
/// doesn't know one (`thinking` is DeepSeek's) never sees it.
public struct AIChatRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var messages: [AIChatMessage]
    public var stream: Bool
    /// 0…2; nil keeps the model's default (reasoning models refuse anything else).
    public var temperature: Double?
    public var maxTokens: Int?
    /// DeepSeek's switch for thinking before answering: `{"type": "enabled" | "disabled"}`. nil sends nothing.
    public var thinking: Bool?

    public init(model: String, messages: [AIChatMessage], stream: Bool = true, temperature: Double? = nil,
                maxTokens: Int? = nil, thinking: Bool? = nil) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.thinking = thinking
    }

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, maxTokens = "max_tokens", thinking
    }

    private struct Thinking: Encodable {
        var type: String
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        if let thinking {
            try container.encode(Thinking(type: thinking ? "enabled" : "disabled"), forKey: .thinking)
        }
    }

    /// The JSON body (keys sorted, so the same request always encodes the same way).
    public func body() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// What a chat sends: the system prompt, then every earlier question with its answer, then the new question.
public enum AIConversation {
    /// `history` holds the earlier (question, answer) pairs in order; pairs without an answer (a failed or stopped
    /// turn that produced nothing) are left out, since the model never said anything to follow up on.
    public static func messages(system: String, history: [(question: String, answer: String)],
                                question: String) -> [AIChatMessage] {
        var messages: [AIChatMessage] = []
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { messages.append(AIChatMessage(.system, system)) }
        for turn in history {
            let answer = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { continue }
            messages.append(AIChatMessage(.user, turn.question))
            messages.append(AIChatMessage(.assistant, answer))
        }
        messages.append(AIChatMessage(.user, question))
        return messages
    }

    /// The default system prompt: short, direct answers in Markdown, in the language of the question.
    public static let defaultSystemPrompt = """
        You are Quick AI in a Mac launcher. Answer directly and concisely: lead with the answer, skip preambles and \
        filler, and add detail only when it helps. Format with Markdown (short paragraphs, lists, fenced code blocks \
        with a language). Reply in the language of the user's message.
        """
}

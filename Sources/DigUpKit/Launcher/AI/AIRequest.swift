import Foundation

/// One message of a chat, as OpenAI-compatible APIs take it.
/// An image carried with a user message. `dataURL` is deliberately already in the wire format (for example,
/// `data:image/png;base64,…`): the app reads a dropped file locally, then this package only has to describe the
/// standard OpenAI-compatible request shape.
public struct AIImageAttachment: Equatable, Sendable {
    public var dataURL: String

    public init(dataURL: String) {
        self.dataURL = dataURL
    }
}

/// One message of a chat, as OpenAI-compatible APIs take it. A text-only message stays exactly that on the wire;
/// image-bearing user messages encode their content as the API's array of text and `image_url` parts.
public struct AIChatMessage: Encodable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }

    public var role: Role
    public var content: String
    /// Images are valid on user messages. Kept separately from `content` so existing text-only callers keep their
    /// simple API and their compact JSON representation.
    public var images: [AIImageAttachment]

    public init(_ role: Role, _ content: String, images: [AIImageAttachment] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    private enum CodingKeys: String, CodingKey { case role, content }

    private enum ContentPart: Encodable {
        case text(String)
        case imageURL(String)

        private enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }

        private struct ImageURL: Encodable {
            let url: String
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .imageURL(let url):
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURL(url: url), forKey: .imageURL)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        guard !images.isEmpty else {
            try container.encode(content, forKey: .content)
            return
        }
        let parts: [ContentPart] = [.text(content)] + images.map { .imageURL($0.dataURL) }
        try container.encode(parts, forKey: .content)
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

    /// As above, while retaining image inputs on the user turns that supplied them. The images stay with the current
    /// in-memory conversation, so a follow-up can still refer to what was dropped.
    public static func messages(system: String,
                                history: [(question: String, answer: String, images: [AIImageAttachment])],
                                question: String, images: [AIImageAttachment]) -> [AIChatMessage] {
        var messages: [AIChatMessage] = []
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { messages.append(AIChatMessage(.system, system)) }
        for turn in history {
            let answer = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { continue }
            messages.append(AIChatMessage(.user, turn.question, images: turn.images))
            messages.append(AIChatMessage(.assistant, answer))
        }
        messages.append(AIChatMessage(.user, question, images: images))
        return messages
    }

    /// A question about some text (Ask AI About Selected Text): the question, then the text set apart in triple
    /// quotes, so instructions inside it are read as text.
    public static func question(_ question: String, about text: String) -> String {
        "\(question)\n\nThe text this is about:\n\"\"\"\n\(text)\n\"\"\""
    }

    /// The default system prompt: short, direct answers in Markdown, in the language of the question.
    public static let defaultSystemPrompt = """
        You are Quick AI in a Mac launcher. Answer directly and concisely: lead with the answer, skip preambles and \
        filler, and add detail only when it helps. Format with Markdown (short paragraphs, lists, fenced code blocks \
        with a language). Reply in the language of the user's message.
        """
}

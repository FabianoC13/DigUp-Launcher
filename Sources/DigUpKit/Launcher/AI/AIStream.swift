import Foundation

/// One event of a server-sent event stream: its type (nil for the default, "message") and its data, with the lines of
/// a multi-line `data:` field joined by "\n".
public struct AIServerSentEvent: Equatable, Sendable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Splits the bytes of a `text/event-stream` response into events, however the network chunks them: a line, or a
/// UTF-8 character, may arrive in two pieces.
///
/// Follows the SSE format: lines end in "\n", "\r\n" or "\r"; a blank line ends an event; `data:` lines add to it
/// (one optional space after the colon is dropped); lines starting with ":" are comments (keep-alives such as
/// ": keep-alive" or ": OPENROUTER PROCESSING"); `id:` and `retry:` are ignored.
public struct AIServerSentEventParser: Sendable {
    private var line: [UInt8] = []
    private var data: [String] = []
    private var event: String?
    private var lastWasCR = false
    private var atStart = true

    public init() {}

    /// The events completed by these bytes.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [AIServerSentEvent] {
        var events: [AIServerSentEvent] = []
        for byte in bytes {
            if byte == 0x0A, lastWasCR {   // the "\n" of a "\r\n": that line already ended
                lastWasCR = false
                continue
            }
            lastWasCR = byte == 0x0D
            if byte == 0x0A || byte == 0x0D {
                if let event = endLine() { events.append(event) }
            } else {
                line.append(byte)
            }
        }
        return events
    }

    /// The stream ended: what's left, as a last event (a server may close without the final blank line).
    public mutating func finish() -> [AIServerSentEvent] {
        var events: [AIServerSentEvent] = []
        if !line.isEmpty, let event = endLine() { events.append(event) }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func endLine() -> AIServerSentEvent? {
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if atStart {
            atStart = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty { return dispatch() }
        if text.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "data": data.append(String(value))
        case "event": event = String(value)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> AIServerSentEvent? {
        defer {
            data = []
            event = nil
        }
        guard !data.isEmpty else { return nil }
        return AIServerSentEvent(event: event, data: data.joined(separator: "\n"))
    }
}

/// What a chat completion stream says, decoded from its chunks.
public enum AIStreamEvent: Equatable, Sendable {
    /// More of the answer.
    case content(String)
    /// More of the model's reasoning (DeepSeek's `reasoning_content`, OpenRouter's `reasoning`): shown apart from the
    /// answer, never mixed into it.
    case reasoning(String)
    /// The answer is complete: "stop", "length" (cut off at the length limit), "content_filter"…
    case finished(reason: String)
    /// The server reported an error in the middle of the stream.
    case failed(AIFailure)
    /// `data: [DONE]`: nothing more is coming.
    case done
}

/// Turns an OpenAI-compatible `/chat/completions` stream (`stream: true`) into `AIStreamEvent`s: the SSE framing, the
/// `[DONE]` marker, each chunk's `choices[0].delta` (content and reasoning), finish reasons and in-stream errors.
public struct AIChatStreamDecoder: Sendable {
    private var parser = AIServerSentEventParser()
    private var provider: String

    /// `provider` names the service in error messages ("DeepSeek").
    public init(provider: String) {
        self.provider = provider
    }

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [AIStreamEvent] {
        parser.feed(bytes).flatMap(decode)
    }

    public mutating func finish() -> [AIStreamEvent] {
        parser.finish().flatMap(decode)
    }

    private func decode(_ event: AIServerSentEvent) -> [AIStreamEvent] {
        let data = event.data.trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { return [.done] }
        guard let json = data.data(using: .utf8) else { return [] }
        if event.event == "error" {
            return [.failed(.stream(AIFailure.serverMessage(in: json) ?? "\(provider) reported an error"))]
        }
        return Self.decodeChunk(json, provider: provider)
    }

    /// The events in one chunk (one `data:` payload), or in a whole non-streamed completion (`message` in place of
    /// `delta`), which some servers send even when asked to stream.
    public static func decodeChunk(_ json: Data, provider: String) -> [AIStreamEvent] {
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: json) else { return [] }
        if let error = chunk.error {
            return [.failed(.stream(error.message ?? "\(provider) reported an error"))]
        }
        var events: [AIStreamEvent] = []
        for choice in (chunk.choices ?? []).prefix(1) {
            let part = choice.delta ?? choice.message
            if let reasoning = part?.reasoning_content ?? part?.reasoning, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            if let content = part?.content, !content.isEmpty {
                events.append(.content(content))
            }
            if let reason = choice.finish_reason, !reason.isEmpty {
                if reason == "error" {
                    events.append(.failed(.stream("\(provider) stopped with an error")))
                } else {
                    events.append(.finished(reason: reason))
                }
            }
        }
        return events
    }

    private struct Chunk: Decodable {
        var choices: [Choice]?
        var error: ErrorBody?
    }

    private struct Choice: Decodable {
        var delta: Part?
        var message: Part?
        var finish_reason: String?
    }

    private struct Part: Decodable {
        var content: String?
        var reasoning_content: String?
        var reasoning: String?
    }

    /// `{"message": "…"}`, or just a string.
    private struct ErrorBody: Decodable {
        var message: String?

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                message = text
            } else {
                let container = try decoder.container(keyedBy: Keys.self)
                message = try container.decodeIfPresent(String.self, forKey: .message)
            }
        }

        private enum Keys: String, CodingKey { case message }
    }
}

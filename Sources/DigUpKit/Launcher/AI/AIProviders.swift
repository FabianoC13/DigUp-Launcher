import Foundation

/// A service Quick AI can ask, through its OpenAI-compatible API (`POST {base}/chat/completions`, `GET {base}/models`)
/// with your own key. The key lives in the Keychain under the preset's `id`.
public struct AIProviderPreset: Identifiable, Equatable, Sendable {
    /// Stable: saved in settings, and the Keychain account of the key.
    public let id: String
    public let name: String
    /// Empty for Custom (you type it).
    public let baseURL: String
    /// Models it's known to have, the default first; the live list comes from `GET /models`.
    public let models: [String]
    /// The model "Regenerate with the other model" (⇧⌘R) uses by default.
    public let alternateModel: String?
    /// Where keys are made.
    public let keyPage: String?
    /// It takes DeepSeek's `thinking` switch (fast answers with thinking off).
    public let thinkingSwitch: Bool
    /// Sent with every request (OpenRouter's app attribution).
    public let headers: [String: String]
    /// Requests go out without a key when none is saved (a local server such as Ollama or LM Studio).
    public let keyOptional: Bool

    public var defaultModel: String { models.first ?? "" }

    public static let deepSeek = AIProviderPreset(
        id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com",
        models: ["deepseek-flash", "deepseek-v4-pro"], alternateModel: "deepseek-v4-pro",
        keyPage: "https://platform.deepseek.com/api_keys", thinkingSwitch: true, headers: [:], keyOptional: false)
    public static let openAI = AIProviderPreset(
        id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
        models: ["gpt-5-mini", "gpt-5"], alternateModel: "gpt-5",
        keyPage: "https://platform.openai.com/api-keys", thinkingSwitch: false, headers: [:], keyOptional: false)
    public static let openRouter = AIProviderPreset(
        id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
        models: ["openrouter/auto"], alternateModel: nil,
        keyPage: "https://openrouter.ai/keys", thinkingSwitch: false,
        headers: ["HTTP-Referer": "https://github.com/ARahim3/DigUp", "X-Title": "DigUp"], keyOptional: false)
    public static let gemini = AIProviderPreset(
        id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
        models: ["gemini-flash-latest", "gemini-pro-latest"], alternateModel: "gemini-pro-latest",
        keyPage: "https://aistudio.google.com/apikey", thinkingSwitch: false, headers: [:], keyOptional: false)
    public static let custom = AIProviderPreset(
        id: "custom", name: "Custom", baseURL: "", models: [], alternateModel: nil, keyPage: nil,
        thinkingSwitch: false, headers: [:], keyOptional: true)

    public static let all: [AIProviderPreset] = [.deepSeek, .openAI, .openRouter, .gemini, .custom]

    /// The preset with this id; DeepSeek for an unknown one.
    public static func named(_ id: String?) -> AIProviderPreset {
        all.first { $0.id == id } ?? .deepSeek
    }
}

/// URLs of an OpenAI-compatible API.
public enum AIEndpoint {
    /// `base` + "/" + `path`, whatever slashes the base ends with. A base pasted with the endpoint on it
    /// (".../v1/chat/completions") is cut back to the base. nil for a base that isn't an http(s) URL.
    public static func url(base: String, path: String) -> URL? {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        for endpoint in ["/chat/completions", "/models"] where base.lowercased().hasSuffix(endpoint) {
            base.removeLast(endpoint.count)
        }
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return URL(string: base + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

/// A model from `GET /models`.
public struct AIModelInfo: Equatable, Sendable, Identifiable {
    public var id: String
    /// The display name when the provider gives one ("DeepSeek-V4.1-Flash").
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }

    /// The chat models in a `/models` response (`{"data": [{"id": …}]}`; Ollama's `{"models": [{"name": …}]}`),
    /// sorted by id. Gemini's "models/" prefix is dropped, and models that can't chat (embeddings, speech, images,
    /// moderation) are left out.
    public static func parse(_ data: Data) -> [AIModelInfo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let entries = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        var models: [AIModelInfo] = []
        for entry in entries {
            guard var id = (entry["id"] as? String) ?? (entry["name"] as? String) else { continue }
            if id.hasPrefix("models/") { id.removeFirst("models/".count) }
            guard !id.isEmpty, isChatModel(id), seen.insert(id).inserted else { continue }
            let name = (entry["name"] as? String).flatMap { $0 == id || $0.hasPrefix("models/") ? nil : $0 }
                ?? (entry["display_name"] as? String) ?? (entry["displayName"] as? String)
            models.append(AIModelInfo(id: id, name: name))
        }
        return models.sorted { $0.id.compare($1.id, options: [.caseInsensitive, .numeric]) == .orderedAscending }
    }

    static let notChat = ["embed", "whisper", "tts", "dall-e", "moderation", "davinci", "babbage", "transcribe",
                          "-audio", "audio-", "realtime", "image", "imagen", "veo", "sora", "aqa", "rerank"]

    /// Whether a model id looks like one you can chat with.
    public static func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return !notChat.contains { lowered.contains($0) }
    }
}

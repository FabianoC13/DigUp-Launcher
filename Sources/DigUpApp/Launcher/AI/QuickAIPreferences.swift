import DigUpKit
import Foundation
import Observation
import Security

/// Quick AI's settings, saved in the app's defaults under "quickAI.…": the provider and its model, the system prompt,
/// what ↩ does with an answer, and when a chat starts over. Keys live in the Keychain (`QuickAIKeys`), never here.
@Observable
final class QuickAIPreferences {
    static let shared = QuickAIPreferences()

    /// What ↩ does with an answer (⌘↩ does the other).
    enum PrimaryAction: String, CaseIterable, Identifiable {
        case paste, copy
        var id: String { rawValue }
    }

    /// The new-chat timeout's choices, in minutes (`AIContinuity.always`: every time, `.never`: never).
    static let newChatChoices: [(minutes: Int, title: String)] = [
        (5, "After 5 minutes"), (10, "After 10 minutes"), (15, "After 15 minutes"), (30, "After 30 minutes"),
        (60, "After 1 hour"), (AIContinuity.always, "Every time"), (AIContinuity.never, "Never"),
    ]

    /// Creativity (temperature) choices; nil keeps the model's own default.
    static let creativityChoices: [(value: Double?, title: String)] = [
        (nil, "Model default"), (0.2, "Low (0.2)"), (0.7, "Medium (0.7)"), (1.1, "High (1.1)"),
    ]

    @ObservationIgnored private let defaults = AppSettings.defaults

    var providerID: String {
        didSet { defaults.set(providerID, forKey: "quickAI.provider") }
    }
    /// The model chosen for each provider (by preset id).
    private var models: [String: String] {
        didSet { defaults.set(models, forKey: "quickAI.models") }
    }
    /// Base URLs typed for the providers that take one (Ollama, Custom).
    private var baseURLs: [String: String] {
        didSet { defaults.set(baseURLs, forKey: "quickAI.baseURLs") }
    }
    /// The system prompt; empty means the default (`AIConversation.defaultSystemPrompt`).
    var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: "quickAI.systemPrompt") }
    }
    var primaryAction: PrimaryAction {
        didSet { defaults.set(primaryAction.rawValue, forKey: "quickAI.primaryAction") }
    }
    /// Minutes without use after which opening Quick AI starts a new chat (`AIContinuity`).
    var newChatAfter: Int {
        didSet { defaults.set(newChatAfter, forKey: "quickAI.newChatAfter") }
    }
    /// DeepSeek's thinking: off answers at once, on reasons first (slower, better for hard questions).
    var thinking: Bool {
        didSet { defaults.set(thinking, forKey: "quickAI.thinking") }
    }
    /// The temperature sent; nil sends none.
    var creativity: Double? {
        didSet {
            if let creativity { defaults.set(creativity, forKey: "quickAI.creativity") }
            else { defaults.removeObject(forKey: "quickAI.creativity") }
        }
    }
    /// Model ids from each provider's `GET /models`, the last time it was asked (Settings, Test Connection).
    private(set) var knownModels: [String: [String]] {
        didSet { defaults.set(knownModels, forKey: "quickAI.knownModels") }
    }
    /// Display names from those lists ("DeepSeek-V4.1-Flash" for "deepseek-flash").
    private(set) var modelNames: [String: String] {
        didSet { defaults.set(modelNames, forKey: "quickAI.modelNames") }
    }
    /// The last four characters of each provider's saved key, to show which one it is without reading the Keychain.
    private(set) var keyHints: [String: String] {
        didSet { defaults.set(keyHints, forKey: "quickAI.keyHints") }
    }

    private init() {
        let defaults = AppSettings.defaults
        providerID = defaults.string(forKey: "quickAI.provider") ?? AIProviderPreset.deepSeek.id
        models = defaults.dictionary(forKey: "quickAI.models") as? [String: String] ?? [:]
        baseURLs = defaults.dictionary(forKey: "quickAI.baseURLs") as? [String: String] ?? [:]
        systemPrompt = defaults.string(forKey: "quickAI.systemPrompt") ?? ""
        primaryAction = PrimaryAction(rawValue: defaults.string(forKey: "quickAI.primaryAction") ?? "") ?? .paste
        newChatAfter = defaults.object(forKey: "quickAI.newChatAfter") == nil
            ? 10 : defaults.integer(forKey: "quickAI.newChatAfter")
        thinking = defaults.bool(forKey: "quickAI.thinking")
        creativity = defaults.object(forKey: "quickAI.creativity") == nil
            ? nil : defaults.double(forKey: "quickAI.creativity")
        knownModels = defaults.dictionary(forKey: "quickAI.knownModels") as? [String: [String]] ?? [:]
        modelNames = defaults.dictionary(forKey: "quickAI.modelNames") as? [String: String] ?? [:]
        keyHints = defaults.dictionary(forKey: "quickAI.keyHints") as? [String: String] ?? [:]
    }

    var provider: AIProviderPreset { AIProviderPreset.named(providerID) }

    /// The model chats use with the current provider.
    var model: String {
        get { model(for: provider) }
        set { models[providerID] = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func model(for preset: AIProviderPreset) -> String {
        if let chosen = models[preset.id], !chosen.isEmpty { return chosen }
        return preset.defaultModel.isEmpty ? (knownModels[preset.id]?.first ?? "") : preset.defaultModel
    }

    /// Where requests go: the preset's URL, or the one typed for Ollama and Custom.
    func baseURL(for preset: AIProviderPreset) -> String {
        if preset.keyOptional, let typed = baseURLs[preset.id], !typed.isEmpty { return typed }
        return preset.baseURL
    }

    func setBaseURL(_ url: String, for preset: AIProviderPreset) {
        baseURLs[preset.id] = url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The system prompt chats run with.
    var effectiveSystemPrompt: String {
        let typed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? AIConversation.defaultSystemPrompt : typed
    }

    /// Every model to offer for a provider: the chosen one, its presets, and what its server listed.
    func modelChoices(for preset: AIProviderPreset) -> [String] {
        var seen = Set<String>()
        return ([model(for: preset)] + preset.models + (knownModels[preset.id] ?? [])).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    /// "DeepSeek-V4.1-Flash" when the server named it, else the id.
    func displayName(_ model: String) -> String {
        modelNames[model] ?? model
    }

    func remember(_ list: [AIModelInfo], for preset: AIProviderPreset) {
        guard !list.isEmpty else { return }
        knownModels[preset.id] = list.map(\.id)
        for info in list {
            if let name = info.name { modelNames[info.id] = name }
        }
    }

    func rememberKeyHint(_ key: String?, for preset: AIProviderPreset) {
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), key.count >= 8 {
            keyHints[preset.id] = String(key.suffix(4))
        } else {
            keyHints[preset.id] = nil
        }
    }

    func keyHint(for preset: AIProviderPreset) -> String? { keyHints[preset.id] }
}

/// API keys in the login Keychain: generic passwords of the service "DigUp Quick AI", one per provider (the account is
/// the preset's id, "deepseek"). Keys read once are kept in memory, so the Keychain is asked (and may ask you to allow
/// DigUp) once per launch at most.
///
/// Reading a key can block while macOS asks for permission: call `load` from a background task, never the main thread.
nonisolated final class QuickAIKeys: @unchecked Sendable {
    static let shared = QuickAIKeys()
    static let service = "DigUp Quick AI"

    enum ReadError: Error, Equatable {
        case missing
        /// The Keychain refused (you clicked Deny, or it's locked).
        case denied(OSStatus)
    }

    private let lock = NSLock()
    private var keys: [String: String] = [:]
    private var present: [String: Bool] = [:]

    /// The key, from memory or the Keychain (which may show its permission prompt and wait for it).
    func load(_ account: String) -> Result<String, ReadError> {
        if let key = lock.withLock({ keys[account] }) { return .success(key) }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            if status == errSecItemNotFound || status == errSecSuccess {
                lock.withLock { present[account] = false }
                return .failure(.missing)
            }
            log("quick ai: the Keychain didn't give the \(account) key (status \(status))")
            return .failure(.denied(status))
        }
        lock.withLock {
            keys[account] = key
            present[account] = true
        }
        return .success(key)
    }

    /// The key when it's already in memory (no Keychain access).
    func cached(_ account: String) -> String? {
        lock.withLock { keys[account] }
    }

    /// Whether a key is saved, from its attributes only: no permission prompt, and quick enough for the main thread.
    func exists(_ account: String) -> Bool {
        if let known = lock.withLock({ present[account] }) { return known }
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        lock.withLock { present[account] = found }
        return found
    }

    /// Saves (or replaces) the key. Returns the Keychain's status.
    func save(_ key: String, account: String) -> OSStatus {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(key.utf8)
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecSuccess {
            // Not there yet, or made by another app in a way that can't be updated: replace it.
            SecItemDelete(baseQuery(account) as CFDictionary)
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "\(Self.service) (\(AIProviderPreset.named(account).name))"
            item[kSecAttrDescription as String] = "API key"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status == errSecSuccess {
            lock.withLock {
                keys[account] = key
                present[account] = true
            }
        } else {
            log("quick ai: saving the \(account) key failed (status \(status))")
        }
        return status
    }

    /// Removes the key. Returns the Keychain's status (errSecItemNotFound counts as done).
    func delete(_ account: String) -> OSStatus {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            lock.withLock {
                keys[account] = nil
                present[account] = false
            }
        } else {
            log("quick ai: removing the \(account) key failed (status \(status))")
        }
        return status
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    /// Words for a Keychain status ("User canceled the operation.").
    static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

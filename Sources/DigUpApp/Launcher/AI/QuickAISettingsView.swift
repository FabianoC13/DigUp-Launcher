import AppKit
import DigUpKit
import SwiftUI

/// Settings → Launcher → Quick AI: the provider, its key (in the Keychain) and model, a connection test, the system
/// prompt, what ↩ does with an answer, when a chat starts over, and the saved chats.
struct QuickAISettingsView: View {
    @Bindable private var preferences = QuickAIPreferences.shared
    private let history = QuickAIHistory.shared

    @State private var keyField = ""
    /// Whether the provider has a key saved (from its Keychain attributes, so no prompt).
    @State private var keySaved = false
    @State private var keyError: String?
    @State private var working = false
    @State private var test: TestResult?
    @State private var modelsNote: String?
    @State private var confirmRemoveKey = false
    @State private var confirmClearHistory = false

    private enum TestResult: Equatable {
        case running
        case passed(String)
        case failed(String)
    }

    private var preset: AIProviderPreset { preferences.provider }

    var body: some View {
        Group {
            Picker("Provider", selection: $preferences.providerID) {
                ForEach(AIProviderPreset.all) { Text($0.name).tag($0.id) }
            }
            if preset.keyOptional {
                TextField("Base URL", text: Binding(get: { preferences.baseURL(for: preset) },
                                                   set: { preferences.setBaseURL($0, for: preset) }),
                          prompt: Text(preset.baseURL.isEmpty ? "https://example.com/v1" : preset.baseURL))
            }
            keyRow
            modelRow
            connectionRow
            if AICredits.balanceURL(providerID: preset.id, baseURL: preferences.baseURL(for: preset)) != nil {
                LabeledContent("Credits left") {
                    QuickAICreditsBar()
                        .onAppear { QuickAICredits.shared.refresh(force: true) }
                }
                if preset.id == AIProviderPreset.deepSeek.id {
                    TextField(value: Binding(get: { QuickAICredits.shared.budget(for: preset.id) },
                                             set: { QuickAICredits.shared.setBudget($0, for: preset.id) }),
                              format: .number, prompt: Text("guessed from the balance")) {
                        Text("Amount you topped up (USD)")
                        Text("What 100% is. DeepSeek only reports the balance.")
                    }
                }
            }
            if preset.thinkingSwitch {
                Toggle(isOn: $preferences.thinking) {
                    Text("Think before answering")
                    Text("Slower, better for hard questions. The reasoning shows folded above the answer.")
                }
            }
            Picker("Creativity", selection: $preferences.creativity) {
                ForEach(QuickAIPreferences.creativityChoices, id: \.title) { Text($0.title).tag($0.value) }
            }
            Picker("↩ on an answer", selection: $preferences.primaryAction) {
                Text("Paste it into the app you came from").tag(QuickAIPreferences.PrimaryAction.paste)
                Text("Copy it to the clipboard").tag(QuickAIPreferences.PrimaryAction.copy)
            }
            Picker("Start a new chat", selection: $preferences.newChatAfter) {
                ForEach(QuickAIPreferences.newChatChoices, id: \.minutes) { Text($0.title).tag($0.minutes) }
            }
            systemPromptRow
            historyRow
        }
        .onAppear(perform: appeared)
        .onChange(of: preferences.providerID) { _, _ in
            keyField = ""
            keyError = nil
            test = nil
            modelsNote = nil
            appeared()
        }
    }

    // MARK: Key

    @ViewBuilder private var keyRow: some View {
        LabeledContent {
            if keySaved {
                HStack(spacing: 8) {
                    Label(preferences.keyHint(for: preset).map { "Saved in Keychain · ••••\($0)" } ?? "Saved in Keychain",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                    Button("Remove…") { confirmRemoveKey = true }
                        .disabled(working)
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("API key", text: $keyField, prompt: Text(preset.keyOptional ? "Optional" : "Paste your key"))
                        .labelsHidden()
                        .frame(minWidth: 180)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .disabled(working || keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } label: {
            Text("API Key")
            if let keyError {
                Text(keyError).foregroundStyle(.red)
            } else if let page = preset.keyPage.flatMap(URL.init(string:)), !keySaved {
                Link("Get a key at \(page.host ?? page.absoluteString)", destination: page)
            }
        }
        .confirmationDialog("Remove the \(preset.name) API key from the Keychain?", isPresented: $confirmRemoveKey) {
            Button("Remove Key", role: .destructive, action: removeKey)
        } message: {
            Text("Quick AI can't ask \(preset.name) until you add a key again.")
        }
    }

    /// The key's state, and the provider's model list when the key is already in memory (asking the Keychain here
    /// could put up its prompt just for opening Settings).
    private func appeared() {
        refreshKeyState()
        if preferences.knownModels[preset.id] == nil, QuickAIKeys.shared.cached(preset.id) != nil { refreshModels() }
    }

    private func refreshKeyState() {
        keySaved = QuickAIKeys.shared.exists(preset.id)
    }

    private func saveKey() {
        let key = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let preset = preset
        working = true
        keyError = nil
        Task {
            // The Keychain may ask to let DigUp change an item another app made: off the main thread.
            let status = await Task.detached { QuickAIKeys.shared.save(key, account: preset.id) }.value
            working = false
            guard status == errSecSuccess else {
                keyError = "Couldn't save it: \(QuickAIKeys.describe(status))"
                return
            }
            preferences.rememberKeyHint(key, for: preset)
            keyField = ""
            refreshKeyState()
            log("quick ai: saved a \(preset.id) key")
            runTest()
        }
    }

    private func removeKey() {
        let preset = preset
        working = true
        Task {
            let status = await Task.detached { QuickAIKeys.shared.delete(preset.id) }.value
            working = false
            if status != errSecSuccess, status != errSecItemNotFound {
                keyError = "Couldn't remove it: \(QuickAIKeys.describe(status))"
            }
            preferences.rememberKeyHint(nil, for: preset)
            test = nil
            refreshKeyState()
        }
    }

    // MARK: Model

    @ViewBuilder private var modelRow: some View {
        let choices = preferences.modelChoices(for: preset)
        LabeledContent {
            HStack(spacing: 8) {
                if choices.isEmpty || preset.id == AIProviderPreset.custom.id {
                    TextField("Model", text: $preferences.model, prompt: Text("Model id"))
                        .labelsHidden()
                }
                if !choices.isEmpty {
                    Picker("Model", selection: $preferences.model) {
                        ForEach(choices, id: \.self) { model in
                            Text(preferences.displayName(model) == model ? model
                                 : "\(preferences.displayName(model)) (\(model))").tag(model)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button {
                    refreshModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Ask \(preset.name) for its models")
                .disabled(working)
            }
        } label: {
            Text("Model")
            Text(modelsNote ?? modelHint)
        }
    }

    private var modelHint: String {
        guard let other = preset.otherModel(than: preferences.model, available: preferences.modelChoices(for: preset))
        else { return "⇧⌘R in Quick AI regenerates with another model." }
        return "⇧⌘R in Quick AI regenerates with \(preferences.displayName(other))."
    }

    private func refreshModels() {
        let preset = preset
        working = true
        modelsNote = "Asking \(preset.name) for its models…"
        Task {
            defer { working = false }
            switch await endpoint(for: preset) {
            case .failure(let failure):
                modelsNote = failure.message
            case .success(let endpoint):
                do {
                    let models = try await QuickAIClient.models(endpoint)
                    preferences.remember(models, for: preset)
                    modelsNote = models.isEmpty ? "\(preset.name) listed no chat models."
                        : "\(preset.name) offers \(models.count) model\(models.count == 1 ? "" : "s")."
                } catch {
                    modelsNote = (error as? AIFailure)?.message ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: Connection

    @ViewBuilder private var connectionRow: some View {
        LabeledContent {
            Button("Test Connection", action: runTest)
                .disabled(working || test == .running)
        } label: {
            Text("Connection")
            switch test {
            case .running: Text("Asking \(preferences.displayName(preferences.model))…")
            case .passed(let text): Text(text).foregroundStyle(.green)
            case .failed(let text): Text(text).foregroundStyle(.red)
            case nil: Text("Sends one tiny question with the key and model above.")
            }
        }
    }

    /// One short question, timed; then the model list, which the same key opens.
    private func runTest() {
        let preset = preset
        let model = preferences.model
        test = .running
        Task {
            let endpoint: QuickAIEndpoint
            switch await self.endpoint(for: preset) {
            case .failure(let failure):
                test = .failed(failure.message)
                return
            case .success(let found):
                endpoint = found
            }
            let request = AIChatRequest(model: model, messages: [AIChatMessage(.user, "Reply with just the word OK.")],
                                        stream: true, thinking: preset.thinkingSwitch ? false : nil)
            do {
                let (answer, time) = try await QuickAIClient.complete(request, to: endpoint)
                let reply = answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)
                test = .passed("Connected: \(preferences.displayName(model)) answered “\(reply)” in "
                    + String(format: "%.1f s", time.quickAISeconds) + ".")
                log("quick ai: connection test passed (\(preset.id), \(model))")
            } catch {
                test = .failed((error as? AIFailure)?.message ?? error.localizedDescription)
                log("quick ai: connection test failed (\(preset.id), \(model))")
            }
            if let models = try? await QuickAIClient.models(endpoint) { preferences.remember(models, for: preset) }
        }
    }

    /// Where to ask and with which key: read off the main thread, since the Keychain may ask to allow DigUp.
    private func endpoint(for preset: AIProviderPreset) async -> Result<QuickAIEndpoint, AIFailure> {
        let baseURL = preferences.baseURL(for: preset)
        if baseURL.isEmpty { return .failure(.noBaseURL) }
        let read = await Task.detached { () -> Result<String, QuickAIKeys.ReadError> in
            if preset.keyOptional, !QuickAIKeys.shared.exists(preset.id) { return .success("") }
            return QuickAIKeys.shared.load(preset.id)
        }.value
        switch read {
        case .success(let key):
            if !key.isEmpty { preferences.rememberKeyHint(key, for: preset) }
            return .success(QuickAIEndpoint(preset: preset, baseURL: baseURL, key: key.isEmpty ? nil : key,
                                            model: preferences.model(for: preset)))
        case .failure(.missing):
            return .failure(.missingKey(provider: preset.name))
        case .failure(.denied(let status)):
            return .failure(.network("DigUp couldn't read the key from the Keychain (\(QuickAIKeys.describe(status)))"))
        }
    }

    // MARK: Prompt and history

    @ViewBuilder private var systemPromptRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("System prompt")
                Spacer()
                Button("Reset to Default") { preferences.systemPrompt = "" }
                    .disabled(preferences.systemPrompt.isEmpty)
            }
            TextEditor(text: $preferences.systemPrompt)
                .font(.system(size: 12))
                .frame(height: 84)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                .overlay(alignment: .topLeading) {
                    if preferences.systemPrompt.isEmpty {
                        Text(AIConversation.defaultSystemPrompt)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
            Text("Sent before every Quick AI question (AI Commands use their own instructions).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var historyRow: some View {
        LabeledContent {
            Button("Clear History…") { confirmClearHistory = true }
                .disabled(history.chats.isEmpty)
        } label: {
            Text("Chat history")
            Text(history.chats.isEmpty ? "No saved chats."
                 : "\(history.chats.count) of the last \(AIChatHistory.limit) chats are kept on this Mac.")
        }
        .task { await history.load() }
        .confirmationDialog("Delete all \(history.chats.count) saved Quick AI chats?", isPresented: $confirmClearHistory) {
            Button("Delete All", role: .destructive) {
                for chat in history.chats { QuickAIChat.shared.forget(chat.id) }
                history.removeAll()
            }
        } message: {
            Text("This can't be undone.")
        }
    }
}

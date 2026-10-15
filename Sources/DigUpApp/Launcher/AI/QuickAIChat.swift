import AppKit
import DigUpKit
import Foundation
import Observation

/// One question and its answer in a Quick AI chat, updated as the answer streams in.
@Observable
final class QuickAITurn: Identifiable {
    enum Phase: Equatable {
        /// Reading the API key (the Keychain may be asking you to allow DigUp).
        case readingKey
        /// Sent; nothing back yet.
        case waiting
        /// The model is reasoning (its thoughts stream into `reasoning`).
        case thinking
        case answering
        case done
        /// ⌘. or Esc stopped it; `answer` holds what came before.
        case stopped
        case failed(AIFailure)
    }

    let id = UUID()
    /// What's sent to the model.
    let question: String
    /// What the chat shows as the question when it differs (an AI command's selected text).
    let shown: String?
    /// The text an AI command rewrote, for showing what changed.
    let original: String?
    var answer = ""
    var reasoning = ""
    var model: String
    var phase: Phase
    /// "The answer was cut off at the length limit."
    var note: String?
    var date: Date
    /// How long the model reasoned before answering, and how long the whole answer took.
    var thinkingTime: Duration?
    var answerTime: Duration?
    /// Show the rewrite as its changes to the original.
    var showsChanges = false

    init(question: String, shown: String? = nil, original: String? = nil, model: String, phase: Phase = .readingKey,
         date: Date = Date()) {
        self.question = question
        self.shown = shown
        self.original = original
        self.model = model
        self.phase = phase
        self.date = date
    }

    var isBusy: Bool {
        switch phase {
        case .readingKey, .waiting, .thinking, .answering: true
        default: false
        }
    }

    var failure: AIFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }

    var record: AIChatRecord.Turn {
        AIChatRecord.Turn(question: question, shown: shown, answer: answer, reasoning: reasoning.isEmpty ? nil : reasoning,
                          model: model, date: date)
    }
}

/// The Quick AI conversation: one at a time, kept between openings of the panel for the "new chat after" setting's
/// time (`AIContinuity`), saved to the history as answers finish. Questions stream from the provider in Settings
/// (`QuickAIClient`); the history so far goes with each one, so follow-ups work.
@Observable
final class QuickAIChat {
    static let shared = QuickAIChat()

    private(set) var id = UUID()
    private(set) var turns: [QuickAITurn] = []
    /// The AI command it was started by (its instructions are the system prompt), nil for a plain chat.
    private(set) var command: AICommand?
    /// Where the command's text came from ("the selected text", "the clipboard").
    private(set) var source: String?
    /// A word for the empty chat: what's happening before the first question ("Reading the selected text…"), or why
    /// there is none ("Select some text first…").
    var notice: String?
    private(set) var created = Date()
    private(set) var lastActivity = Date()
    /// A model picked for this chat (⇧⌘R, "Regenerate with…"), for the provider it was picked with.
    private var modelOverride: (provider: String, model: String)?
    /// Bumped each time answer text lands, so the view can follow the stream.
    private(set) var tick = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Text that arrived but isn't drawn yet: it's applied at most every `flushInterval`, not per token.
    @ObservationIgnored private var pending: (turn: QuickAITurn, answer: String, reasoning: String)?
    @ObservationIgnored private var flushScheduled = false
    /// The panel closed while the key was being read (the Keychain's prompt takes the keyboard, which hides the
    /// panel): it comes back with the answer once the key is there.
    @ObservationIgnored private var reopenWhenKeyArrives = false
    /// To bring the panel back after the Keychain prompt.
    @ObservationIgnored weak var context: LauncherContext?

    static let flushInterval: Duration = .milliseconds(40)

    private var preferences: QuickAIPreferences { .shared }

    var isBusy: Bool { turns.last?.isBusy ?? false }
    var lastTurn: QuickAITurn? { turns.last }
    /// The most recent answer (the last turn's, when it has one).
    var lastAnswer: String? {
        turns.last { !$0.answer.isEmpty }?.answer
    }
    /// The model the next question goes to.
    var model: String {
        if let modelOverride, modelOverride.provider == preferences.providerID { return modelOverride.model }
        return preferences.model
    }
    var systemPrompt: String { command?.instructions ?? preferences.effectiveSystemPrompt }
    var title: String {
        guard let first = turns.first else { return "New Chat" }
        if let command { return AIChatTitle.make("\(command.title): \(first.shown ?? first.question)") }
        return AIChatTitle.make(first.shown ?? first.question)
    }

    // MARK: Asking

    /// Sends a question (a follow-up when the chat has turns).
    func ask(_ question: String, shown: String? = nil, original: String? = nil) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isBusy { stop() }
        notice = nil
        let turn = QuickAITurn(question: text, shown: shown, original: original, model: model)
        turns.append(turn)
        lastActivity = Date()
        tick += 1
        run(turn)
    }

    /// The last question again (⌘R), with `model` if given (⇧⌘R, "Regenerate with…").
    func regenerate(model newModel: String? = nil) {
        guard let turn = turns.last else { return }
        if isBusy { stop() }
        if let newModel { modelOverride = (preferences.providerID, newModel) }
        turn.answer = ""
        turn.reasoning = ""
        turn.note = nil
        turn.thinkingTime = nil
        turn.answerTime = nil
        turn.model = model
        turn.date = Date()
        lastActivity = Date()
        tick += 1
        run(turn)
    }

    /// Stops the answer coming in (⌘., Esc); what came is kept.
    func stop() {
        guard let turn = turns.last, turn.isBusy else { return }
        if turn.phase == .readingKey {
            // The Keychain is asking (that hid the panel): carry on, and come back when it's answered.
            reopenWhenKeyArrives = true
            return
        }
        task?.cancel()
        task = nil
        flush()
        turn.phase = .stopped
        if turn.answer.isEmpty, turn.reasoning.isEmpty { turn.note = "Stopped before an answer came." }
        lastActivity = Date()
        save()
    }

    /// The panel closed or Quick AI was left: stop, and count from now for the new-chat timeout.
    func closed() {
        stop()
        lastActivity = Date()
    }

    /// A fresh chat (⌘N, an AI command); the current one stays in the history.
    func startNew(command: AICommand? = nil, source: String? = nil) {
        reset(saving: true, command: command, source: source)
    }

    /// The chat with this id was deleted from the history: if it's the current one, it's dropped without saving it
    /// again.
    func forget(_ chatID: UUID) {
        guard chatID == id else { return }
        reset(saving: false, command: nil, source: nil)
    }

    private func reset(saving: Bool, command: AICommand?, source: String?) {
        task?.cancel()
        task = nil
        pending = nil
        if saving { save() }
        id = UUID()
        turns = []
        self.command = command
        self.source = source
        notice = nil
        modelOverride = nil
        created = Date()
        lastActivity = Date()
        reopenWhenKeyArrives = false
        tick += 1
    }

    /// Opening Quick AI: carries on with this chat unless it's been idle past the setting's timeout, or was an AI
    /// command's (those are continued from the history).
    func prepareForOpening() {
        if command != nil || !AIContinuity.continues(lastActivity: lastActivity, minutes: preferences.newChatAfter) {
            startNew()
        }
    }

    /// A saved chat, to read and continue.
    func open(_ record: AIChatRecord) {
        guard record.id != id else { return }
        startNew()
        id = record.id
        command = record.command.flatMap(AICommand.init(rawValue:))
        created = record.created
        turns = record.turns.map { saved in
            let turn = QuickAITurn(question: saved.question, shown: saved.shown,
                                   original: command?.replacesSelection == true ? saved.shown : nil,
                                   model: saved.model, phase: .done, date: saved.date)
            turn.answer = saved.answer
            turn.reasoning = saved.reasoning ?? ""
            return turn
        }
        if let last = record.turns.last { modelOverride = (record.provider, last.model) }
        tick += 1
    }

    var record: AIChatRecord {
        AIChatRecord(id: id, title: title, created: created, updated: lastActivity, provider: preferences.providerID,
                     command: command?.rawValue, turns: turns.map(\.record))
    }

    private func save() {
        guard turns.contains(where: { !$0.answer.isEmpty }) else { return }
        QuickAIHistory.shared.save(record)
    }

    // MARK: Streaming

    private func run(_ turn: QuickAITurn) {
        task?.cancel()
        pending = nil
        reopenWhenKeyArrives = false
        let history = turns.prefix { $0 !== turn }.map { (question: $0.question, answer: $0.answer) }
        let messages = AIConversation.messages(system: systemPrompt, history: Array(history), question: turn.question)
        let preset = preferences.provider
        let request = AIChatRequest(model: turn.model, messages: messages, stream: true,
                                    temperature: preferences.creativity,
                                    thinking: preset.thinkingSwitch ? preferences.thinking : nil)
        let baseURL = preferences.baseURL(for: preset)
        turn.phase = .readingKey
        log("quick ai: asking \(preset.name) \(turn.model) (\(messages.count) messages)")
        task = Task { [weak self] in
            // The key first, off the main thread: the Keychain may ask you to allow DigUp, and waits for the answer.
            let read = await Task.detached { () -> Result<String, QuickAIKeys.ReadError> in
                if preset.keyOptional, !QuickAIKeys.shared.exists(preset.id) { return .success("") }
                return QuickAIKeys.shared.load(preset.id)
            }.value
            guard let self, !Task.isCancelled, turn.phase == .readingKey else { return }
            let key: String
            switch read {
            case .success(let found):
                key = found
                if !found.isEmpty, preferences.keyHint(for: preset) == nil { preferences.rememberKeyHint(found, for: preset) }
            case .failure(.missing):
                finish(turn, failure: .missingKey(provider: preset.name))
                return
            case .failure(.denied(let status)):
                finish(turn, failure: .network("DigUp couldn't read the API key from the Keychain ("
                    + QuickAIKeys.describe(status).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) + ")."))
                return
            }
            if reopenWhenKeyArrives { reopen() }
            turn.phase = .waiting
            let endpoint = QuickAIEndpoint(preset: preset, baseURL: baseURL, key: key.isEmpty ? nil : key,
                                           model: turn.model)
            await stream(request, to: endpoint, into: turn)
        }
    }

    private func stream(_ request: AIChatRequest, to endpoint: QuickAIEndpoint, into turn: QuickAITurn) async {
        let clock = ContinuousClock()
        let start = clock.now
        var reason: String?
        do {
            for try await event in QuickAIClient.stream(request, to: endpoint) {
                guard !Task.isCancelled else { return }
                switch event {
                case .reasoning(let text):
                    if turn.phase == .waiting { turn.phase = .thinking }
                    add(reasoning: text, to: turn)
                case .content(let text):
                    if turn.phase != .answering {
                        if turn.phase == .thinking { turn.thinkingTime = clock.now - start }
                        turn.phase = .answering
                    }
                    add(answer: text, to: turn)
                case .finished(let finish):
                    reason = finish
                case .failed(let failure):
                    throw failure
                case .done:
                    break
                }
            }
            guard !Task.isCancelled else { return }
            flush()
            turn.answerTime = clock.now - start
            if turn.answer.isEmpty {
                finish(turn, failure: reason == "content_filter" ? .blocked(provider: endpoint.providerName)
                    : .emptyAnswer(provider: endpoint.providerName))
                return
            }
            switch reason {
            case "length": turn.note = "The answer was cut off at the model's length limit."
            case "content_filter": turn.note = "\(endpoint.providerName)'s content filter cut the answer short."
            default: break
            }
            turn.phase = .done
            lastActivity = Date()
            log("quick ai: \(endpoint.model) answered \(turn.answer.count) characters in "
                + String(format: "%.1f s", (clock.now - start).quickAISeconds))
            save()
            QuickAIDebug.answered(self)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            flush()
            finish(turn, failure: error as? AIFailure ?? .network(error.localizedDescription))
        }
    }

    private func finish(_ turn: QuickAITurn, failure: AIFailure) {
        turn.phase = .failed(failure)
        lastActivity = Date()
        tick += 1
        log("quick ai: failed: \(failure)")
        if reopenWhenKeyArrives { reopen() }
        save()
        QuickAIDebug.answered(self)
    }

    /// The panel back on Quick AI, after the Keychain's prompt took it away.
    private func reopen() {
        reopenWhenKeyArrives = false
        guard let context, !context.isPanelVisible else { return }
        context.push(QuickAIMode(chat: self))
    }

    private func add(answer: String = "", reasoning: String = "", to turn: QuickAITurn) {
        if let pending, pending.turn === turn {
            self.pending = (turn, pending.answer + answer, pending.reasoning + reasoning)
        } else {
            flush()
            pending = (turn, answer, reasoning)
        }
        // The first words show at once; after that, a few times a second is smooth and much cheaper to draw.
        if turn.answer.isEmpty, !answer.isEmpty {
            flush()
        } else if !flushScheduled {
            flushScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: Self.flushInterval)
                self?.flush()
            }
        }
    }

    private func flush() {
        flushScheduled = false
        guard let pending else { return }
        self.pending = nil
        if !pending.reasoning.isEmpty { pending.turn.reasoning += pending.reasoning }
        if !pending.answer.isEmpty { pending.turn.answer += pending.answer }
        tick += 1
    }
}

/// The saved Quick AI chats (newest first, at most `AIChatHistory.limit`), in Launcher/AI/history.json.
@Observable
final class QuickAIHistory {
    static let shared = QuickAIHistory()

    private(set) var chats: [AIChatRecord] = []
    private(set) var loaded = false
    @ObservationIgnored private var history = AIChatHistory()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    static var file: URL {
        Launcher.directory.appendingPathComponent("AI", isDirectory: true).appendingPathComponent("history.json")
    }

    /// Reads the file (off the main thread); saves made before it finished are kept on top of it.
    func load() async {
        guard !loaded else { return }
        let file = Self.file
        let saved = await Task.detached { () -> AIChatHistory? in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: file) else { return nil }
            do {
                return try decoder.decode(AIChatHistory.self, from: data)
            } catch {
                log("quick ai: the chat history couldn't be read: \(error)")
                return nil
            }
        }.value
        guard !loaded else { return }
        if let saved {
            // Chats saved while it was being read go on top of it.
            var merged = saved
            for chat in history.chats.reversed() { merged.save(chat) }
            history = merged
        }
        loaded = true
        chats = history.chats
    }

    func save(_ chat: AIChatRecord) {
        history.save(chat)
        chats = history.chats
        write()
    }

    func delete(_ id: UUID) {
        history.delete(id)
        chats = history.chats
        write()
    }

    func removeAll() {
        history.removeAll()
        chats = []
        write()
    }

    func chat(_ id: UUID) -> AIChatRecord? {
        history.chat(id)
    }

    /// Written half a second after the last change, off the main thread, atomically.
    private func write() {
        saveTask?.cancel()
        let history = self.history
        let file = Self.file
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await Task.detached {
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601   // the file reads plainly
                    try encoder.encode(history).write(to: file, options: .atomic)
                } catch {
                    log("quick ai: saving the chat history failed: \(error)")
                }
            }.value
        }
    }
}

extension Duration {
    /// Seconds as a Double (3.25).
    nonisolated var quickAISeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

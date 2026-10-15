import DigUpKit
import Foundation

/// A provider, ready to ask: where, with which key and model.
nonisolated struct QuickAIEndpoint: Sendable {
    var preset: AIProviderPreset
    var baseURL: String
    var key: String?
    var model: String

    /// "DeepSeek", for messages.
    var providerName: String { preset.name }
}

/// Talks to an OpenAI-compatible API: streams chat completions (`POST /chat/completions`, `stream: true`), asks once
/// (Test Connection) and lists models (`GET /models`). Every failure comes out as an `AIFailure` with words for the
/// person asking; cancelling the consuming task stops the request. `AIWatchdog` decides when waiting has gone on too
/// long: keep-alive comments keep a connection busy, so URLSession's own timeouts never fire on a stuck answer.
nonisolated enum QuickAIClient {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(AIWatchdog.idle)
        configuration.timeoutIntervalForResource = 20 * 60
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "DigUp Quick AI"]
        return URLSession(configuration: configuration)
    }()

    /// The answer to `chat` as it streams: content and reasoning deltas, the finish reason, then `.done`.
    static func stream(_ chat: AIChatRequest, to endpoint: QuickAIEndpoint) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let request = try makeRequest(endpoint, path: "chat/completions", body: try chat.body(), stream: true)
                    try await watched(endpoint) { watch in
                        try await read(request, endpoint: endpoint, watch: watch) { event in
                            watch.received()
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: failure(error, endpoint: endpoint))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One whole answer and how long it took, for Test Connection: streamed like a chat, so the same limits apply.
    static func complete(_ chat: AIChatRequest, to endpoint: QuickAIEndpoint) async throws -> (String, Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        var answer = ""
        for try await event in stream(chat, to: endpoint) {
            switch event {
            case .content(let text): answer += text
            case .failed(let failure): throw failure
            default: break
            }
        }
        return (answer, clock.now - start)
    }

    /// The provider's chat models (`GET /models`).
    static func models(_ endpoint: QuickAIEndpoint) async throws -> [AIModelInfo] {
        do {
            var request = try makeRequest(endpoint, path: "models", body: nil, stream: false)
            request.timeoutInterval = TimeInterval(AIWatchdog.firstByte)
            let (data, response) = try await session.data(for: request)
            try check(response, body: data, endpoint: endpoint)
            return AIModelInfo.parse(data)
        } catch {
            throw failure(error, endpoint: endpoint)
        }
    }

    // MARK: Requests

    private static func makeRequest(_ endpoint: QuickAIEndpoint, path: String, body: Data?,
                                    stream: Bool) throws -> URLRequest {
        guard let url = AIEndpoint.url(base: endpoint.baseURL, path: path) else {
            throw endpoint.preset.keyOptional ? AIFailure.noBaseURL : AIFailure.network("the base URL isn't valid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        for (field, value) in endpoint.preset.requestHeaders(key: endpoint.key) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Streams the response's events to `yield`, after checking its status.
    private static func read(_ request: URLRequest, endpoint: QuickAIEndpoint, watch: QuickAIWatch,
                             yield: (AIStreamEvent) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        watch.responded()
        guard let http = response as? HTTPURLResponse else { throw AIFailure.network("the server didn't answer HTTP.") }
        if !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 64 * 1024 { break }
            }
            try check(response, body: body, endpoint: endpoint)
        }
        // Some servers answer a streamed request with one whole completion.
        if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            for event in AIChatStreamDecoder.decodeChunk(body, provider: endpoint.providerName) { yield(event) }
            yield(.done)
            return
        }
        var decoder = AIChatStreamDecoder(provider: endpoint.providerName)
        var line: [UInt8] = []
        line.reserveCapacity(1024)
        for try await byte in bytes {
            line.append(byte)
            guard byte == 0x0A else { continue }
            for event in decoder.feed(line) {
                yield(event)
                if event == .done { return }
            }
            line.removeAll(keepingCapacity: true)
        }
        for event in decoder.feed(line) + decoder.finish() { yield(event) }
    }

    /// Throws the failure an error status stands for.
    private static func check(_ response: URLResponse, body: Data, endpoint: QuickAIEndpoint) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        log("quick ai: \(endpoint.providerName) answered HTTP \(http.statusCode) for \(endpoint.model)")
        throw AIFailure.from(status: http.statusCode, body: body, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                             provider: endpoint.providerName, model: endpoint.model)
    }

    /// Runs `work`, failing with `AIWatchdog`'s verdict once it has waited too long (checked every half second).
    private static func watched(_ endpoint: QuickAIEndpoint,
                                _ work: @escaping @Sendable (QuickAIWatch) async throws -> Void) async throws {
        let watch = QuickAIWatch()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work(watch) }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(500))
                    if let failure = watch.failure(provider: endpoint.providerName) { throw failure }
                }
            }
            // The work finishing (or either one failing) ends both.
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// The failure an error stands for: an `AIFailure` as it is, a networking error in words, cancellation as it is.
    static func failure(_ error: Error, endpoint: QuickAIEndpoint) -> Error {
        if error is AIFailure || error is CancellationError { return error }
        if let error = error as? URLError {
            return AIFailure.from(networkCode: error.errorCode, host: error.failingURL?.host ?? URL(
                string: endpoint.baseURL)?.host, provider: endpoint.providerName, seconds: AIWatchdog.firstByte,
                description: error.localizedDescription) ?? CancellationError()
        }
        return AIFailure.network(error.localizedDescription)
    }
}

/// How far a request has got, set from its task and read by its watchdog.
nonisolated final class QuickAIWatch: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var headers: ContinuousClock.Instant?
    private var lastEvent: ContinuousClock.Instant?

    init() {
        start = clock.now
    }

    /// The response's headers came.
    func responded() { lock.withLock { headers = clock.now } }
    /// A piece of the answer (or of the reasoning) came.
    func received() { lock.withLock { lastEvent = clock.now } }

    func failure(provider: String) -> AIFailure? {
        let (headers, lastEvent) = lock.withLock { (self.headers, self.lastEvent) }
        func seconds(_ instant: ContinuousClock.Instant?) -> Double? { instant.map { ($0 - start).quickAISeconds } }
        return AIWatchdog.failure(now: (clock.now - start).quickAISeconds, headers: seconds(headers),
                                  lastEvent: seconds(lastEvent), provider: provider)
    }
}

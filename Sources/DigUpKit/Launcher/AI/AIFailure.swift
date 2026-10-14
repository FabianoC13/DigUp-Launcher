import Foundation

/// Why a question to the AI got no answer, in words for the person asking: a refused key, an empty balance, a rate
/// limit, the network. Built from the HTTP status and the error body the provider sends back (`from(status:…)`).
public enum AIFailure: Error, Equatable, Sendable {
    /// No API key is saved for the provider.
    case missingKey(provider: String)
    /// The Custom provider has no usable base URL.
    case noBaseURL
    /// 401 or 403. `detail` is the provider's reason when it isn't just "invalid key" (a region it doesn't serve).
    case keyRefused(provider: String, detail: String?)
    /// 402, or OpenAI's 429 `insufficient_quota`.
    case noBalance(provider: String)
    /// 429: too many requests; `retryAfter` in seconds when the provider said.
    case rateLimited(provider: String, retryAfter: Double?)
    /// 404: usually a model name the provider doesn't have (or a wrong base URL).
    case notFound(provider: String, model: String, detail: String?)
    /// 400 or 422: the provider didn't accept the request.
    case badRequest(provider: String, detail: String)
    /// 503 or 529: the provider is overloaded.
    case overloaded(provider: String)
    /// Any other status.
    case serverError(provider: String, status: Int, detail: String?)
    case offline
    /// Nothing came back in time.
    case timedOut(provider: String, seconds: Int)
    case unreachable(host: String)
    case network(String)
    /// An error the provider reported in the middle of the stream.
    case stream(String)
    /// The stream ended without any answer.
    case emptyAnswer(provider: String)
    /// The provider's content filter stopped the answer.
    case blocked(provider: String)

    /// One or two sentences for the conversation view.
    public var message: String {
        switch self {
        case .missingKey(let provider):
            return "There's no \(provider) API key yet. Add one in Settings → Launcher → Quick AI."
        case .noBaseURL:
            return "The custom provider needs a base URL (such as http://localhost:11434/v1). Add it in Settings → "
                + "Launcher → Quick AI."
        case .keyRefused(let provider, let detail):
            let base = "The API key was refused by \(provider). Check it in Settings → Launcher → Quick AI."
            return detail.map { "\(base) (\($0))" } ?? base
        case .noBalance(let provider):
            return "Your \(provider) balance is empty. Top it up on \(provider)'s site, then try again."
        case .rateLimited(let provider, let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "\(provider) is rate limiting requests. Try again in \(Self.duration(retryAfter))."
            }
            return "\(provider) is rate limiting requests. Try again in a moment."
        case .notFound(let provider, let model, let detail):
            let base = "\(provider) doesn't know the model “\(model)”. Pick another one in Settings → Launcher → "
                + "Quick AI."
            return detail.map { "\(base) (\($0))" } ?? base
        case .badRequest(let provider, let detail):
            return "\(provider) didn't accept the request: \(detail)"
        case .overloaded(let provider):
            return "\(provider) is overloaded right now. Try again in a moment."
        case .serverError(let provider, let status, let detail):
            let base = "\(provider) had a problem (HTTP \(status))."
            return detail.map { "\(base) \($0)" } ?? "\(base) Try again in a moment."
        case .offline:
            return "You're offline. Quick AI needs the internet to reach your provider."
        case .timedOut(let provider, let seconds):
            return "\(provider) didn't answer within \(seconds) seconds. Try again."
        case .unreachable(let host):
            return "Can't reach \(host). Check the connection, or the base URL in Settings → Launcher → Quick AI."
        case .network(let detail):
            return "The connection failed: \(detail)"
        case .stream(let detail):
            return detail
        case .emptyAnswer(let provider):
            return "\(provider) sent back an empty answer. Try again, or rephrase the question."
        case .blocked(let provider):
            return "\(provider)'s content filter stopped the answer."
        }
    }

    /// The fix is in Settings (the key, the balance, the model).
    public var needsSettings: Bool {
        switch self {
        case .missingKey, .noBaseURL, .keyRefused, .noBalance, .notFound: return true
        default: return false
        }
    }

    /// The failure an HTTP error response stands for. `retryAfter` is the Retry-After header, `model` the one asked.
    public static func from(status: Int, body: Data, retryAfter: String?, provider: String, model: String,
                            now: Date = Date()) -> AIFailure {
        let detail = serverMessage(in: body)
        let code = serverCode(in: body)
        switch status {
        case 401:
            return .keyRefused(provider: provider, detail: nil)
        case 403:
            return .keyRefused(provider: provider, detail: detail)
        case 402:
            return .noBalance(provider: provider)
        case 429:
            if let code, ["insufficient_quota", "billing_hard_limit_reached"].contains(code) {
                return .noBalance(provider: provider)
            }
            return .rateLimited(provider: provider, retryAfter: retryAfterSeconds(retryAfter, now: now))
        case 404:
            return .notFound(provider: provider, model: model, detail: detail)
        case 400, 422:
            return .badRequest(provider: provider, detail: detail ?? "HTTP \(status)")
        case 408:
            return .timedOut(provider: provider, seconds: 30)
        case 503, 529:
            return .overloaded(provider: provider)
        default:
            return .serverError(provider: provider, status: status, detail: detail)
        }
    }

    /// The failure a networking error stands for, from its `URLError` code (-1009 offline, -1001 timed out…); nil for
    /// -999, a cancelled request, which is no failure. `host` is the server's name, `seconds` the timeout.
    public static func from(networkCode code: Int, host: String?, provider: String, seconds: Int,
                            description: String) -> AIFailure? {
        switch code {
        case -999:
            return nil
        case -1009, -1020, -1018:   // not connected, data not allowed, roaming off
            return .offline
        case -1001:
            return .timedOut(provider: provider, seconds: seconds)
        case -1003, -1004, -1006:   // can't find the host, can't connect, DNS failed
            return .unreachable(host: host ?? provider)
        case -1005:
            return .network("the connection was lost. Try again.")
        case -1206 ... -1200:   // TLS: failed, untrusted or expired certificate…
            return .network("a secure connection to \(host ?? provider) couldn't be made.")
        default:
            return .network(description)
        }
    }

    /// The human part of an error body: `{"error": {"message": …}}` (OpenAI, DeepSeek, OpenRouter),
    /// `{"error": "…"}`, `[{"error": {…}}]` (Gemini), `{"message": …}` or `{"detail": …}`. Trimmed, without DeepSeek's
    /// "(request_id: …)", at most 300 characters; nil when there's none.
    public static func serverMessage(in body: Data) -> String? {
        guard let object = errorObject(in: body) else {
            let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // Plain text (a proxy's "Bad Gateway"), not an HTML page.
            return text.isEmpty || text.hasPrefix("<") ? nil : text
        }
        var message: String?
        if let error = object["error"] as? [String: Any] {
            message = error["message"] as? String
        } else if let error = object["error"] as? String {
            message = error
        }
        message = message ?? object["message"] as? String ?? object["detail"] as? String
        guard var text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let range = text.range(of: #"\s*\(request[ _]id:[^)]*\)"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        return text.count > 300 ? String(text.prefix(299)) + "…" : text
    }

    /// The machine part of an error body: `error.code` (a string or a number), else `error.type`.
    public static func serverCode(in body: Data) -> String? {
        guard let error = errorObject(in: body)?["error"] as? [String: Any] else { return nil }
        if let code = error["code"] as? String, !code.isEmpty { return code }
        if let code = error["code"] as? Int { return String(code) }
        return error["type"] as? String
    }

    private static func errorObject(in body: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: body) else { return nil }
        if let object = json as? [String: Any] { return object }
        return (json as? [Any])?.first as? [String: Any]
    }

    /// Seconds to wait from a Retry-After header: a number of seconds, or an HTTP date.
    public static func retryAfterSeconds(_ header: String?, now: Date = Date()) -> Double? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Double(header) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// "12 s", "3 min".
    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.up))
        return whole < 90 ? "\(whole) s" : "\((whole + 59) / 60) min"
    }
}

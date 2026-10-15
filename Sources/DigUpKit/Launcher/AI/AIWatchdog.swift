import Foundation

/// When a streamed answer has waited too long. Three limits, because a request can hang at three points: before the
/// server answers at all, after it has answered but before any of the answer comes (DeepSeek, when overloaded, sends
/// ": keep-alive" comments for minutes and nothing else, which keeps the connection itself from ever timing out), and
/// in the middle of the answer.
public enum AIWatchdog {
    /// Seconds to the response's headers.
    public static let firstByte = 30
    /// Seconds from the headers to the first piece of the answer or of the reasoning.
    public static let firstEvent = 60
    /// Seconds between two pieces once the answer is coming.
    public static let idle = 120

    /// The failure to stop with, or nil to keep waiting. Times are seconds since the request was sent: `now`, when the
    /// headers came (`headers`), and when the last piece of the answer came (`lastEvent`).
    public static func failure(now: Double, headers: Double?, lastEvent: Double?, provider: String) -> AIFailure? {
        if let lastEvent {
            return now - lastEvent > Double(idle) ? .stalled(provider: provider, seconds: idle, started: true) : nil
        }
        if let headers {
            return now - headers > Double(firstEvent)
                ? .stalled(provider: provider, seconds: firstEvent, started: false) : nil
        }
        return now > Double(firstByte) ? .timedOut(provider: provider, seconds: firstByte) : nil
    }
}

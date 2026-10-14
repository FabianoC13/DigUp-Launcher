import Foundation

/// The websites a focus session blocks: entries as you'd type them, and whether a page's host is one of them.
public enum FocusDomains {
    /// A block list entry as a bare domain: "https://www.YouTube.com/feed" → "youtube.com", "*.reddit.com" →
    /// "reddit.com". Nil when it isn't a host name ("hello world", "localhost").
    public static func normalize(_ entry: String) -> String? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let end = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<end]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }   // user:pass@host
        if let colon = text.lastIndex(of: ":") { text = String(text[..<colon]) }                // a port
        while text.hasPrefix("*.") || text.hasPrefix(".") { text.removeFirst(text.hasPrefix("*.") ? 2 : 1) }
        while text.hasSuffix(".") { text.removeLast() }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }),
              labels.allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
        return text
    }

    /// The listed domain `host` is, or is under ("m.youtube.com" is under "youtube.com"; "notyoutube.com" isn't).
    public static func match(host: String, domains: [String]) -> String? {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        return domains.first { domain in host == domain || host.hasSuffix("." + domain) }
    }

    /// The host of a web page's address, nil for anything else (file:, about:, the browser's own pages).
    public static func host(ofPage address: String) -> String? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// The listed domain a page's address is on, nil when it isn't blocked.
    public static func blocked(address: String, domains: [String]) -> String? {
        guard !domains.isEmpty, let host = host(ofPage: address) else { return nil }
        return match(host: host, domains: domains)
    }
}

/// How long a focus session lasts, typed before its goal: "45m write the report", "1h30 taxes", "until 4:30pm".
public enum FocusDuration {
    public static let minimum: TimeInterval = 60
    public static let maximum: TimeInterval = 24 * 3600

    /// The duration at the start of `text` and the goal after it, nil when it doesn't start with one. Numbers need a
    /// unit ("25m", "2 hours"), so a goal like "3 chapters" isn't read as minutes; a number alone is minutes.
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current)
        -> (seconds: TimeInterval, goal: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("until ") || lower.hasPrefix("till ") {
            return parseUntil(trimmed, now: now, calendar: calendar)
        }
        let characters = Array(lower)
        var index = 0
        var total: TimeInterval = 0
        var lastUnit: TimeInterval?
        var groups = 0
        while true {
            var cursor = index
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            var number = ""
            while cursor < characters.count, characters[cursor].isNumber || (characters[cursor] == "." && !number.isEmpty) {
                number.append(characters[cursor])
                cursor += 1
            }
            guard !number.isEmpty, let value = Double(number) else { break }
            var unitStart = cursor
            while unitStart < characters.count, characters[unitStart] == " " { unitStart += 1 }
            var unit = ""
            var unitEnd = unitStart
            while unitEnd < characters.count, characters[unitEnd].isLetter {
                unit.append(characters[unitEnd])
                unitEnd += 1
            }
            // "1h30": a unit may run straight into the next number.
            let atEnd = unitEnd >= characters.count || characters[unitEnd] == " " || characters[unitEnd].isNumber
            if let seconds = unitSeconds[unit], atEnd {
                total += value * seconds
                lastUnit = seconds
                index = unitEnd
            } else if lastUnit == 3600, cursor >= characters.count || characters[cursor] == " " {
                total += value * 60   // "1h30 taxes": the minutes after the hours (the goal's word isn't a unit)
                lastUnit = 60
                index = cursor
            } else if unit.isEmpty, groups == 0, cursor >= characters.count {
                total = value * 60    // a number alone: minutes
                index = cursor
            } else {
                break
            }
            groups += 1
        }
        guard groups > 0, total >= minimum, total <= maximum else { return nil }
        let goal = String(trimmed.dropFirst(index)).trimmingCharacters(in: .whitespaces)
        return (total.rounded(), goal)
    }

    private static let unitSeconds: [String: TimeInterval] = [
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
    ]

    /// "until 4:30pm write", "until 16:30 write": the time from now to the next such time.
    private static func parseUntil(_ text: String, now: Date, calendar: Calendar) -> (seconds: TimeInterval, goal: String)? {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2 else { return nil }
        var timeText = words[1].lowercased()
        var used = 2
        if words.count > 2, ["am", "pm", "a.m.", "p.m."].contains(words[2].lowercased()) {
            timeText += words[2].lowercased()
            used = 3
        }
        var meridiem: String?
        for suffix in ["a.m.", "p.m.", "am", "pm"] where timeText.hasSuffix(suffix) {
            meridiem = suffix.hasPrefix("a") ? "am" : "pm"
            timeText.removeLast(suffix.count)
            break
        }
        let parts = timeText.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let hourValue = Int(parts[0]),
              parts.count == 1 || parts[1].count == 2, let minute = parts.count == 2 ? Int(parts[1]) : 0,
              (0..<60).contains(minute) else { return nil }
        var hour = hourValue
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        }
        guard (0..<24).contains(hour),
              var end = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        if end <= now, let tomorrow = calendar.date(byAdding: .day, value: 1, to: end) { end = tomorrow }
        let seconds = end.timeIntervalSince(now).rounded()
        guard seconds >= minimum, seconds <= maximum else { return nil }
        return (seconds, words.dropFirst(used).joined(separator: " "))
    }

    /// "25 minutes", "1 hour", "1 h 30 min".
    public static func describe(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60, rest = minutes % 60
        if rest == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours) h \(rest) min"
    }

    /// A countdown as the menu bar shows it: "18:42", "1:05:09".
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        let tail = (minutes < 10 && hours > 0 ? "0" : "") + "\(minutes):" + (rest < 10 ? "0" : "") + "\(rest)"
        return hours > 0 ? "\(hours):\(tail)" : (minutes < 10 ? "0" : "") + tail
    }
}

/// The browsers a focus session watches, and the AppleScript that reads and replaces their front tab.
public enum FocusBrowser {
    /// Safari names the front tab "current tab"; Chromium browsers name it "active tab".
    public enum Dialect: Sendable { case safari, chromium }

    /// Bundle id → name and dialect.
    public static let known: [String: (name: String, dialect: Dialect)] = [
        "com.apple.Safari": ("Safari", .safari),
        "com.apple.SafariTechnologyPreview": ("Safari Technology Preview", .safari),
        "com.google.Chrome": ("Google Chrome", .chromium),
        "com.google.Chrome.beta": ("Google Chrome Beta", .chromium),
        "com.google.Chrome.canary": ("Google Chrome Canary", .chromium),
        "company.thebrowser.Browser": ("Arc", .chromium),
        "com.brave.Browser": ("Brave Browser", .chromium),
        "com.microsoft.edgemac": ("Microsoft Edge", .chromium),
        "com.vivaldi.Vivaldi": ("Vivaldi", .chromium),
        "com.operasoftware.Opera": ("Opera", .chromium),
        "org.chromium.Chromium": ("Chromium", .chromium),
    ]

    private static func tab(_ dialect: Dialect) -> String { dialect == .safari ? "current tab" : "active tab" }

    /// Returns the front window's tab's address ("" with no window).
    public static func readScript(bundleID: String, dialect: Dialect) -> String {
        """
        tell application id "\(bundleID)"
            if (count of windows) is 0 then return ""
            return URL of \(tab(dialect)) of front window
        end tell
        """
    }

    /// Loads `item 1 of argv` in the front window's tab, if it's still on a page of `item 2 of argv` (the user may have
    /// moved on since it was read).
    public static func redirectScript(bundleID: String, dialect: Dialect) -> String {
        """
        on run argv
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return "gone"
                set theTab to \(tab(dialect)) of front window
                if (URL of theTab) does not contain (item 2 of argv) then return "moved"
                set URL of theTab to (item 1 of argv)
                return "blocked"
            end tell
        end run
        """
    }

    /// Closes the front window's tab (when loading the block page didn't work).
    public static func closeScript(bundleID: String, dialect: Dialect) -> String {
        """
        tell application id "\(bundleID)"
            if (count of windows) is 0 then return "gone"
            close \(tab(dialect)) of front window
            return "closed"
        end tell
        """
    }
}

extension FocusBrowser {
    /// The block page's file name: tabs showing it are found again by it, to give them their pages back.
    public static let blockPageName = "digup-focus-blocked.html"

    /// The block page's address for one blocked tab: `#t=<token>&h=<host>` tells the page what was blocked, and the
    /// token finds the tab again when the session ends.
    public static func blockPageAddress(page: URL, token: String, host: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        let encodedHost = host.addingPercentEncoding(withAllowedCharacters: allowed) ?? host
        return page.absoluteString + "#t=" + token + "&h=" + encodedHost
    }

    /// Gives every tab showing the block page its page back: `argv` is pairs of a tab's token and its address. Returns
    /// how many tabs it restored.
    public static func restoreScript(bundleID: String) -> String {
        """
        on run argv
            set restored to 0
            tell application id "\(bundleID)"
                repeat with theWindow in windows
                    repeat with theTab in tabs of theWindow
                        try
                            set theAddress to URL of theTab
                            if theAddress contains "\(blockPageName)#t=" then
                                repeat with i from 1 to (count of argv) by 2
                                    if theAddress contains ("#t=" & (item i of argv) & "&") then
                                        set URL of theTab to (item (i + 1) of argv)
                                        set restored to restored + 1
                                        exit repeat
                                    end if
                                end repeat
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return restored
        end run
        """
    }
}

/// A focus session's clock: how long it has run and how long it has left, not counting pauses. Wall-clock dates, so a
/// Mac that slept through the end of a session finds it over when it wakes.
public struct FocusTimer: Codable, Equatable, Sendable {
    public var started: Date
    /// Nil: until it's stopped.
    public var duration: TimeInterval?
    /// Paused since then; nil while it runs.
    public var pausedAt: Date?
    /// The pauses before the current one.
    public var pausedBefore: TimeInterval

    public init(started: Date, duration: TimeInterval?) {
        self.started = started
        self.duration = duration
        pausedAt = nil
        pausedBefore = 0
    }

    public var isPaused: Bool { pausedAt != nil }

    /// Focused time so far.
    public func elapsed(at now: Date) -> TimeInterval {
        let paused = pausedBefore + (pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        return max(0, now.timeIntervalSince(started) - paused)
    }

    /// Time left; nil for a session without an end.
    public func remaining(at now: Date) -> TimeInterval? {
        duration.map { max(0, $0 - elapsed(at: now)) }
    }

    public func isFinished(at now: Date) -> Bool {
        remaining(at: now).map { $0 <= 0 } ?? false
    }

    public mutating func pause(at now: Date) {
        guard pausedAt == nil else { return }
        pausedAt = now
    }

    public mutating func resume(at now: Date) {
        guard let pausedAt else { return }
        pausedBefore += max(0, now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
    }

    /// More time ("Add 10 Minutes"); a session without an end stays without one.
    public mutating func extend(by seconds: TimeInterval) {
        if let duration { self.duration = duration + seconds }
    }
}

import Foundation

/// A video call service whose links My Schedule finds in an event, to join the call with one key.
public enum MeetingService: String, Sendable, CaseIterable {
    case zoom, googleMeet, teams, webex, faceTime, whereby, around, slackHuddle, skype, blueJeans, chime, jitsi

    public var name: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .faceTime: "FaceTime"
        case .whereby: "Whereby"
        case .around: "Around"
        case .slackHuddle: "Slack Huddle"
        case .skype: "Skype"
        case .blueJeans: "BlueJeans"
        case .chime: "Amazon Chime"
        case .jitsi: "Jitsi Meet"
        }
    }

    /// The apps that open its links natively (`MeetingLink.nativeURL`), newest first.
    public var appBundleIDs: [String] {
        switch self {
        case .zoom: ["us.zoom.xos"]
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        default: []
        }
    }

    /// The service a link is a call of: the host and, where the host also serves other pages, the path that a call's
    /// link has ("zoom.us/j/…", not "zoom.us/pricing").
    public static func of(_ url: URL) -> MeetingService? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        let hasPath = path.count > 1
        func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if under("zoom.us") || under("zoomgov.com") {
            return ["/j/", "/my/", "/s/", "/w/", "/wc/"].contains { path.hasPrefix($0) } ? .zoom : nil
        }
        if host == "meet.google.com" { return hasPath ? .googleMeet : nil }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") ? .teams : nil
        }
        if under("webex.com") { return hasPath ? .webex : nil }
        if host == "facetime.apple.com" { return path.hasPrefix("/join") ? .faceTime : nil }
        if under("whereby.com") { return hasPath ? .whereby : nil }
        if host == "around.co" || host == "meet.around.co" { return hasPath ? .around : nil }
        if host == "app.slack.com" { return path.hasPrefix("/huddle/") ? .slackHuddle : nil }
        if host == "join.skype.com" { return hasPath ? .skype : nil }
        if under("bluejeans.com") { return hasPath && path.dropFirst().first?.isNumber == true ? .blueJeans : nil }
        if host == "chime.aws" { return hasPath ? .chime : nil }
        if host == "meet.jit.si" { return hasPath ? .jitsi : nil }
        return nil
    }
}

/// A call's link found in an event.
public struct MeetingLink: Equatable, Sendable {
    public let service: MeetingService
    public let url: URL

    public init(service: MeetingService, url: URL) {
        self.service = service
        self.url = url
    }

    /// The link for the service's own app, to open when it's installed: Zoom's `zoommtg://<host>/join?confno=…&pwd=…`
    /// (for "/j/<number>" links), Teams' `msteams://…`. Nil when the web link is the only way.
    public var nativeURL: URL? {
        switch service {
        case .zoom:
            let parts = url.path.split(separator: "/")
            guard let host = url.host, let j = parts.firstIndex(of: "j"), j + 1 < parts.count,
                  parts[j + 1].allSatisfy(\.isNumber) else { return nil }
            var components = URLComponents()
            components.scheme = "zoommtg"
            components.host = host
            components.path = "/join"
            var items = [URLQueryItem(name: "action", value: "join"),
                         URLQueryItem(name: "confno", value: String(parts[j + 1]))]
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let password = query.first(where: { $0.name == "pwd" })?.value {
                items.append(URLQueryItem(name: "pwd", value: password))
            }
            components.queryItems = items
            return components.url
        case .teams:
            let text = url.absoluteString
            guard let range = text.range(of: "://") else { return nil }
            return URL(string: "msteams" + text[range.lowerBound...])
        default:
            return nil
        }
    }
}

public enum MeetingLinks {
    /// The first call link in an event: its URL field, then its location, then its notes.
    public static func find(url: String?, location: String?, notes: String?) -> MeetingLink? {
        for text in [url, location, notes] {
            guard let text, !text.isEmpty else { continue }
            if let link = links(in: text).first { return link }
        }
        return nil
    }

    /// Every call link in `text`, in order: "https://…" anywhere in it (in angle brackets, Markdown links, HTML), and
    /// links written without the scheme ("meet.google.com/abc-defg-hij").
    public static func links(in text: String) -> [MeetingLink] {
        let separators: Set<Character> = ["<", ">", "\"", "'", "`", "|", "\u{00A0}"]
        var found: [MeetingLink] = []
        for word in text.split(whereSeparator: { $0.isWhitespace || separators.contains($0) }) {
            var token = Substring(word)
            if let scheme = token.range(of: "https://", options: .caseInsensitive)
                ?? token.range(of: "http://", options: .caseInsensitive) {
                token = token[scheme.lowerBound...]
            } else if !token.contains(".") || !token.contains("/") {
                continue
            }
            while let last = token.last, ".,;:!?)]}*".contains(last) { token = token.dropLast() }
            let string = token.lowercased().hasPrefix("http") ? String(token) : "https://" + token
            guard let url = URL(string: string), let service = MeetingService.of(url) else { continue }
            if !found.contains(where: { $0.url == url }) { found.append(MeetingLink(service: service, url: url)) }
        }
        return found
    }
}

/// Days and times the way My Schedule says them.
public enum ScheduleDay {
    /// Days from `now`'s day to `date`'s day: 0 today, 1 tomorrow, -1 yesterday.
    public static func offset(of date: Date, from now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// A day's heading: "Today", "Tomorrow", the weekday within the week ("Thursday"), then weekday and date
    /// ("Tuesday, Oct 21").
    public static func title(for date: Date, now: Date, calendar: Calendar = .current,
                             locale: Locale = .current) -> String {
        let offset = offset(of: date, from: now, calendar: calendar)
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            let template = (2...6).contains(offset) ? "EEEE" : "EEEEMMMd"
            formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
            return formatter.string(from: date)
        }
    }

    /// "Now" while an event runs, "In 5 min" or "In 1 h 20 min" when it starts within `window`, nil otherwise.
    public static func countdown(start: Date, end: Date, now: Date, within window: TimeInterval = 3600) -> String? {
        if start <= now { return now < end ? "Now" : nil }
        let seconds = start.timeIntervalSince(now)
        guard seconds <= window else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "In \(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "In \(hours) h" : "In \(hours) h \(rest) min"
    }

    /// Whether a call is close enough to join from the root search: from `lead` before it starts until it ends.
    public static func isJoinable(start: Date, end: Date, now: Date, lead: TimeInterval = 15 * 60) -> Bool {
        start.addingTimeInterval(-lead) <= now && now < end
    }
}

/// Free time between your events, to paste into a message ("Copy Availability").
public enum ScheduleAvailability {
    /// The free slots in working hours on the next `days` working days (today included while it has working time
    /// left), at least `minimum` long. `busy` is every event that takes your time; overlaps are fine. Slots start on
    /// a quarter hour.
    public static func freeSlots(busy: [DateInterval], from now: Date, days: Int, workStartHour: Int,
                                 workEndHour: Int, minimum: TimeInterval = 30 * 60, skipWeekends: Bool = true,
                                 calendar: Calendar = .current) -> [DateInterval] {
        guard days > 0, (0..<24).contains(workStartHour), workEndHour > workStartHour, workEndHour <= 24 else {
            return []
        }
        let merged = merge(busy)
        var slots: [DateInterval] = []
        var counted = 0
        var dayOffset = 0
        while counted < days, dayOffset < days + 14 {
            defer { dayOffset += 1 }
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)),
                  let open = calendar.date(byAdding: .hour, value: workStartHour, to: day),
                  let close = calendar.date(byAdding: .hour, value: workEndHour, to: day) else { continue }
            if skipWeekends, calendar.isDateInWeekend(day) { continue }
            let start = max(open, roundedUpToQuarter(now, calendar: calendar))
            guard start < close else { continue }   // today's working hours are over: it doesn't count
            counted += 1
            var cursor = start
            for event in merged where event.end > cursor && event.start < close {
                if event.start > cursor, event.start.timeIntervalSince(cursor) >= minimum {
                    slots.append(DateInterval(start: cursor, end: event.start))
                }
                cursor = max(cursor, event.end)
            }
            if close.timeIntervalSince(cursor) >= minimum { slots.append(DateInterval(start: cursor, end: close)) }
        }
        return slots
    }

    /// Overlapping and touching intervals as one, in order.
    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// The next quarter hour from `date` (itself when it's on one).
    static func roundedUpToQuarter(_ date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
        let seconds = (parts.minute ?? 0) * 60 + (parts.second ?? 0)
        let extra = seconds % 900
        if extra == 0, (parts.nanosecond ?? 0) == 0 { return date }
        let floored = date.addingTimeInterval(-Double(extra) - Double(parts.nanosecond ?? 0) / 1e9)
        return floored.addingTimeInterval(900)
    }
}

/// An event as text: its times in a row, the details to paste, your free time to share.
public enum ScheduleText {
    /// "10:00 – 10:30", "All day", or with dates when it spans days ("Oct 14, 22:00 – Oct 15, 01:00").
    public static func timeRange(start: Date, end: Date, allDay: Bool, calendar: Calendar = .current,
                                 locale: Locale = .current) -> String {
        let lastDay = allDay ? end.addingTimeInterval(-1) : end
        if allDay {
            guard !calendar.isDate(start, inSameDayAs: lastDay), lastDay > start else { return "All day" }
            return "All day, " + interval(start, lastDay, date: .medium, time: .none, calendar: calendar,
                                          locale: locale)
        }
        if calendar.isDate(start, inSameDayAs: end) || end <= start {
            return interval(start, end, date: .none, time: .short, calendar: calendar, locale: locale)
        }
        return interval(start, end, date: .medium, time: .short, calendar: calendar, locale: locale)
    }

    /// An event's details to paste into a message: title, when, where, the call's link, who, notes.
    public static func details(title: String, start: Date, end: Date, allDay: Bool, location: String?, link: URL?,
                               url: URL?, attendees: [String], notes: String?, calendar: Calendar = .current,
                               locale: Locale = .current) -> String {
        var lines = [title]
        let day = interval(start, start, date: .full, time: .none, calendar: calendar, locale: locale)
        lines.append("\(day), \(timeRange(start: start, end: end, allDay: allDay, calendar: calendar, locale: locale))")
        if let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty,
           location != link?.absoluteString {
            lines.append("Location: \(location)")
        }
        if let link { lines.append("Join: \(link.absoluteString)") }
        if let url, url != link { lines.append("Link: \(url.absoluteString)") }
        if !attendees.isEmpty { lines.append("Attendees: \(attendees.joined(separator: ", "))") }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("")
            lines.append(notes)
        }
        return lines.joined(separator: "\n")
    }

    /// Free slots as lines to paste, one day per line: "Thursday, Oct 15: 9:15 – 10:00 AM, 1:00 – 5:00 PM".
    /// "No free time" when there's none.
    public static func availability(_ slots: [DateInterval], calendar: Calendar = .current,
                                    locale: Locale = .current) -> String {
        guard !slots.isEmpty else { return "No free time" }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = locale
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        var lines: [String] = []
        var current: Date?
        var ranges: [String] = []
        for slot in slots.sorted(by: { $0.start < $1.start }) {
            if let day = current, !calendar.isDate(day, inSameDayAs: slot.start) {
                lines.append("\(dayFormatter.string(from: day)): \(ranges.joined(separator: ", "))")
                ranges = []
            }
            if ranges.isEmpty { current = slot.start }
            ranges.append(interval(slot.start, slot.end, date: .none, time: .short, calendar: calendar, locale: locale))
        }
        if let day = current { lines.append("\(dayFormatter.string(from: day)): \(ranges.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    private static func interval(_ start: Date, _ end: Date, date: DateIntervalFormatter.Style,
                                 time: DateIntervalFormatter.Style, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = date
        formatter.timeStyle = time
        return formatter.string(from: start, to: end)
    }
}

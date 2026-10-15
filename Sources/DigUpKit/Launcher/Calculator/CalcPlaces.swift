import Foundation

/// A place a time can be in: a city, country, airport, zone abbreviation or UTC offset.
public struct CalcPlace: Sendable, Equatable {
    /// As shown ("Tokyo", "EST", "UTC+5:30").
    public var name: String
    public var zone: TimeZone
}

/// Finds the time zone of a place name: the built-in table of cities, countries, airports and nicknames, then zone
/// abbreviations and UTC offsets, then the last part of every zone identifier ("Sao_Paulo", "Kolkata").
public enum CalcPlaces {
    private static let index: [String: (zone: String, name: String)] = {
        var index: [String: (String, String)] = [:]
        for (zone, names) in CalcPlaceTable.rows {
            let entries = names.split(separator: ";").map(String.init)
            guard let first = entries.first else { continue }
            for entry in entries {
                let isNickname = entry == entry.lowercased() || (entry.count == 3 && entry == entry.uppercased())
                let key = fold(entry)
                if index[key] == nil { index[key] = (zone, isNickname ? first : entry) }
            }
        }
        return index
    }()

    private static let identifiers: [String: String] = {
        var identifiers: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            identifiers[id.lowercased()] = id
            if let last = id.split(separator: "/").last {
                let key = fold(last.replacingOccurrences(of: "_", with: " "))
                if identifiers[key] == nil { identifiers[key] = id }
            }
        }
        return identifiers
    }()

    static func fold(_ text: String) -> String {
        FuzzyMatch.normalize(text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "’", with: "'"))
    }

    public static func place(_ text: String) -> CalcPlace? {
        let key = fold(text)
        guard !key.isEmpty, key.count <= 40 else { return nil }
        if let offset = utcOffset(key) {
            return TimeZone(secondsFromGMT: offset.seconds).map { CalcPlace(name: offset.name, zone: $0) }
        }
        if let seconds = CalcPlaceTable.abbreviations[key], let zone = TimeZone(secondsFromGMT: seconds) {
            return CalcPlace(name: key.uppercased(), zone: zone)
        }
        if let found = index[key], let zone = TimeZone(identifier: found.zone) {
            return CalcPlace(name: found.name, zone: zone)
        }
        if let id = identifiers[key], let zone = TimeZone(identifier: id) {
            let name = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
            return CalcPlace(name: name, zone: zone)
        }
        return nil
    }

    /// "utc+3", "gmt-5", "utc+05:30", "utc +9".
    static func utcOffset(_ key: String) -> (seconds: Int, name: String)? {
        let text = key.replacingOccurrences(of: " ", with: "")
        guard let prefix = ["utc", "gmt"].first(where: { text.hasPrefix($0) }) else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
        let parts = rest.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let hours = Int(parts[0]), hours <= 14,
              parts[0].count <= 2 else { return nil }
        let minutes = parts.count == 2 ? Int(parts[1]) : 0
        guard let minutes, minutes < 60 else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        let name = "UTC\(sign)\(hours)" + (minutes > 0 ? String(format: ":%02d", minutes) : "")
        return (seconds, name)
    }

    /// "GMT+9", "GMT-3", "GMT+5:30" at `date`.
    public static func offsetName(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        if seconds == 0 { return "GMT" }
        let sign = seconds < 0 ? "-" : "+"
        let hours = abs(seconds) / 3600, minutes = abs(seconds) % 3600 / 60
        return "GMT\(sign)\(hours)" + (minutes > 0 ? String(format: ":%02d", minutes) : "")
    }

    /// "+9h", "-3h", "+5h 30m", "±0h".
    public static func differenceName(_ seconds: Int) -> String {
        if seconds == 0 { return "±0h" }
        let sign = seconds < 0 ? "-" : "+"
        let hours = abs(seconds) / 3600, minutes = abs(seconds) % 3600 / 60
        return "\(sign)\(hours)h" + (minutes > 0 ? " \(minutes)m" : "")
    }
}

/// A time of day typed in a question: "5pm", "5:30 pm", "17:30", "9.15am", "noon", "midnight".
struct CalcClock: Equatable {
    var hour: Int
    var minute: Int

    static func parse(_ input: String) -> CalcClock? {
        var text = input.lowercased().replacingOccurrences(of: ".", with: ":").replacingOccurrences(of: " ", with: "")
        switch text {
        case "noon", "midday": return CalcClock(hour: 12, minute: 0)
        case "midnight": return CalcClock(hour: 0, minute: 0)
        default: break
        }
        var meridiem: String?
        for suffix in ["a:m:", "p:m:", "am", "pm", "a", "p"] where text.hasSuffix(suffix) {
            meridiem = String(suffix.prefix(1))
            text.removeLast(suffix.count)
            break
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let hour = Int(parts[0]), parts[0].count <= 2,
              parts[0].allSatisfy(\.isASCIIDigit) else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let m = Int(parts[1]), m < 60 else { return nil }
            minute = m
        } else if meridiem == nil {
            // A bare "5" is a number, not a time.
            return nil
        }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            return CalcClock(hour: meridiem == "a" ? hour % 12 : hour % 12 + 12, minute: minute)
        }
        guard hour < 24 else { return nil }
        return CalcClock(hour: hour, minute: minute)
    }

    /// Today's date at this time in `zone`.
    func date(on day: Date, in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)
    }
}

/// Dates and times written for the reader's locale.
enum CalcDateText {
    static func string(_ date: Date, template: String, zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// "2:00 AM" / "02:00".
    static func time(_ date: Date, zone: TimeZone, locale: Locale) -> String {
        string(date, template: "jmm", zone: zone, locale: locale)
    }

    /// "Thursday, October 16, 2026".
    static func fullDate(_ date: Date, zone: TimeZone, locale: Locale) -> String {
        string(date, template: "EEEEMMMMdyyyy", zone: zone, locale: locale)
    }

    /// "Thursday, October 16, 2026 at 2:00 AM".
    static func dateTime(_ date: Date, zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "Tomorrow", "Yesterday" or nil, comparing the calendar day of `date` in `zone` with that of `reference` in
    /// `referenceZone`.
    static func dayWord(_ date: Date, zone: TimeZone, relativeTo reference: Date, in referenceZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let a = calendar.dateComponents([.year, .month, .day], from: date)
        calendar.timeZone = referenceZone
        let b = calendar.dateComponents([.year, .month, .day], from: reference)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? zone
        guard let dayA = calendar.date(from: a), let dayB = calendar.date(from: b),
              let days = calendar.dateComponents([.day], from: dayB, to: dayA).day else { return nil }
        switch days {
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 0: return nil
        default: return days > 0 ? "+\(days) days" : "\(days) days"
        }
    }
}

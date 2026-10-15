import Foundation

/// Time zone answers: "time in tokyo", "tokyo time", "now in PST", "5pm london in new york", "3pm EST to CET",
/// "noon in sydney", "time diff paris", "time in 4 hours", "time in 4 hours in san francisco",
/// "time in brisbane + 4 hours", and clock arithmetic ("3:45pm + 5").
public enum CalcTimeZones {
    public static func answer(_ input: String, env: CalcEnvironment) -> CalcAnswer? {
        var text = CalcText.clean(input)
        guard !text.isEmpty, text.count <= 80 else { return nil }
        text = text.replacingOccurrences(of: "?", with: "").trimmingCharacters(in: .whitespaces)
        if let rest = CalcText.dropAnyPrefix(["what time is it in", "what's the time in", "whats the time in",
                                              "what time in", "current time in", "local time in", "the time in"],
                                             from: text) {
            text = "time in " + rest
        }
        if let rest = CalcText.dropAnyPrefix(["time difference between", "time difference with", "time difference",
                                              "time diff", "timediff", "diff"], from: text) {
            return difference(rest, env: env)
        }
        if let rest = CalcText.dropAnyPrefix(["time in", "time at", "now in", "time now in", "time"], from: text) {
            return current(rest, env: env)
        }
        if let rest = CalcText.dropSuffix("time", from: text) ?? CalcText.dropSuffix("now", from: text),
           let place = CalcPlaces.place(rest) {
            return currentTime(in: place, delta: 0, env: env)
        }
        if let found = clockArithmetic(text, env: env) { return found }
        return CalcText.splitLast(text, separators: ["in", "to", "into", "as", "→", "->", "="]) { left, right in
            convert(left, to: right, env: env)
        }
    }

    // MARK: Forms

    /// "time in tokyo", "time in 4 hours", "time in 4 hours in sf", "time in brisbane + 4 hours".
    static func current(_ rest: String, env: CalcEnvironment) -> CalcAnswer? {
        guard !rest.isEmpty else { return nil }
        if let place = CalcPlaces.place(rest) { return currentTime(in: place, delta: 0, env: env) }
        // "brisbane + 4 hours", "london - 30 min".
        for sign in [" + ", " - "] {
            if let range = rest.range(of: sign, options: .backwards),
               let place = CalcPlaces.place(String(rest[..<range.lowerBound])),
               let seconds = duration(String(rest[range.upperBound...]), env: env) {
                return currentTime(in: place, delta: sign == " + " ? seconds : -seconds, env: env)
            }
        }
        // "4 hours", "4 hours in san francisco".
        if let seconds = duration(rest, env: env) {
            return currentTime(in: nil, delta: seconds, env: env)
        }
        return CalcText.splitLast(rest, separators: ["in", "at"]) { left, right in
            guard let seconds = duration(left, env: env), let place = CalcPlaces.place(right) else { return nil }
            return currentTime(in: place, delta: seconds, env: env)
        }
    }

    /// The time now (plus `delta` seconds) in `place`, or here.
    static func currentTime(in place: CalcPlace?, delta: Double, env: CalcEnvironment) -> CalcAnswer {
        let instant = env.now.addingTimeInterval(delta)
        let zone = place?.zone ?? env.timeZone
        var expression = place.map { "Time in \($0.name)" } ?? "Time"
        if delta != 0 {
            let span = CalcConversion.timespan(abs(delta), format: env.format)
            expression = place.map { "Time in \($0.name) \(delta > 0 ? "+" : "-") \(span)" }
                ?? (delta > 0 ? "Time in \(span)" : "Time \(span) ago")
        }
        return answer(instant, in: zone, placeName: place?.name, from: env.timeZone, fromName: nil,
                      reference: env.now, expression: expression, env: env)
    }

    /// "5pm london in new york", "3pm est to cet", "noon in sydney", "london 9am in tokyo".
    static func convert(_ left: String, to right: String, env: CalcEnvironment) -> CalcAnswer? {
        guard let target = CalcPlaces.place(right) else { return nil }
        let words = left.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        // The clock is the first one, two or three words ("5pm", "5 pm", "5:30 p m") or the last ones.
        var clock: CalcClock?
        var placeText = ""
        for count in stride(from: min(3, words.count), through: 1, by: -1) {
            if let found = CalcClock.parse(words.prefix(count).joined(separator: " ")) {
                clock = found
                placeText = words.dropFirst(count).joined(separator: " ")
                break
            }
            if let found = CalcClock.parse(words.suffix(count).joined(separator: " ")) {
                clock = found
                placeText = words.dropLast(count).joined(separator: " ")
                break
            }
        }
        guard let clock else { return nil }
        var source: CalcPlace?
        if !placeText.isEmpty {
            guard let found = CalcPlaces.place(placeText) else { return nil }
            source = found
        }
        let sourceZone = source?.zone ?? env.timeZone
        guard let instant = clock.date(on: env.now, in: sourceZone) else { return nil }
        let sourceTime = CalcDateText.time(instant, zone: sourceZone, locale: env.locale)
        let expression = "\(sourceTime)\(source.map { " \($0.name)" } ?? "") → \(target.name)"
        return answer(instant, in: target.zone, placeName: target.name, from: sourceZone, fromName: source?.name,
                      reference: instant, expression: expression, env: env)
    }

    /// "time diff paris", "time difference between tokyo and london".
    static func difference(_ rest: String, env: CalcEnvironment) -> CalcAnswer? {
        var from: CalcPlace?
        var to: CalcPlace?
        if let range = rest.range(of: " and ") {
            from = CalcPlaces.place(String(rest[..<range.lowerBound]))
            to = CalcPlaces.place(String(rest[range.upperBound...]))
            guard from != nil, to != nil else { return nil }
        } else {
            to = CalcPlaces.place(rest)
        }
        guard let to else { return nil }
        let fromZone = from?.zone ?? env.timeZone
        let seconds = to.zone.secondsFromGMT(for: env.now) - fromZone.secondsFromGMT(for: env.now)
        let hours = Double(abs(seconds)) / 3600
        let amount = "\(env.format.number(hours)) \(hours == 1 ? "hour" : "hours")"
        let reference = from?.name ?? "you"
        let result = seconds == 0 ? "Same time" : "\(amount) \(seconds > 0 ? "ahead" : "behind")"
        let caption = "\(to.name) (\(CalcPlaces.offsetName(to.zone, at: env.now))) is "
            + (seconds == 0 ? "on the same time as \(reference)"
                : "\(amount) \(seconds > 0 ? "ahead of" : "behind") \(reference)")
            + " · \(CalcDateText.time(env.now, zone: to.zone, locale: env.locale)) there now"
        return CalcAnswer(kind: .timeZone, result: result,
                          expression: "Time difference: \(from.map { "\($0.name) → " } ?? "")\(to.name)",
                          caption: caption, copyText: CalcPlaces.differenceName(seconds))
    }

    /// "3:45pm + 5" (hours), "9am + 90 min", "17:30 - 2 hours".
    static func clockArithmetic(_ text: String, env: CalcEnvironment) -> CalcAnswer? {
        for sign in [" + ", " - "] {
            guard let range = text.range(of: sign), let clock = CalcClock.parse(String(text[..<range.lowerBound]))
            else { continue }
            let amount = String(text[range.upperBound...])
            let seconds: Double
            if let hours = Double(amount) {
                seconds = hours * 3600
            } else if let found = duration(amount, env: env) {
                seconds = found
            } else {
                return nil
            }
            guard let start = clock.date(on: env.now, in: env.timeZone) else { return nil }
            let end = start.addingTimeInterval(sign == " + " ? seconds : -seconds)
            let time = CalcDateText.time(end, zone: env.timeZone, locale: env.locale)
            let day = CalcDateText.dayWord(end, zone: env.timeZone, relativeTo: start, in: env.timeZone)
            let startText = CalcDateText.time(start, zone: env.timeZone, locale: env.locale)
            let span = CalcConversion.timespan(seconds, format: env.format)
            return CalcAnswer(kind: .date, result: day.map { "\($0) \(time)" } ?? time,
                              expression: "\(startText)\(sign)\(span)",
                              caption: CalcDateText.fullDate(end, zone: env.timeZone, locale: env.locale),
                              copyText: time)
        }
        return nil
    }

    // MARK: Helpers

    /// Seconds in "4 hours", "90 min", "1h 30min", nil if it isn't a duration.
    static func duration(_ text: String, env: CalcEnvironment) -> Double? {
        let scanner = CalcUnitScanner(env: CalcEnvironment(now: env.now, timeZone: env.timeZone, locale: env.locale))
        guard let quantity = scanner.quantity(text),
              let (resolved, category) = CalcConversion.resolve(quantity, toward: nil), category == .duration,
              let seconds = CalcConversion.total(resolved, category: category, env: env), seconds.isFinite,
              abs(seconds) < 1e11 else { return nil }
        return seconds
    }

    /// The answer for `instant` shown in `zone`: "Tomorrow 2:00 AM · +9h".
    static func answer(_ instant: Date, in zone: TimeZone, placeName: String?, from sourceZone: TimeZone,
                       fromName: String?, reference: Date, expression: String, env: CalcEnvironment) -> CalcAnswer {
        let time = CalcDateText.time(instant, zone: zone, locale: env.locale)
        let day = CalcDateText.dayWord(instant, zone: zone, relativeTo: reference, in: sourceZone)
        let difference = zone.secondsFromGMT(for: instant) - sourceZone.secondsFromGMT(for: instant)
        var result = day.map { "\($0) \(time)" } ?? time
        if difference != 0 { result += " · \(CalcPlaces.differenceName(difference))" }
        var caption = CalcDateText.fullDate(instant, zone: zone, locale: env.locale)
        caption += " · \(placeName ?? "Local time") (\(CalcPlaces.offsetName(zone, at: instant)))"
        if difference != 0 {
            let hours = Double(abs(difference)) / 3600
            caption += " · \(env.format.number(hours)) \(hours == 1 ? "hour" : "hours") "
                + "\(difference > 0 ? "ahead of" : "behind") \(fromName ?? "you")"
        }
        return CalcAnswer(kind: .timeZone, result: result, expression: expression, caption: caption, copyText: time)
    }
}

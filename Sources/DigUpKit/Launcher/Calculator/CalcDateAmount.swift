import Foundation

/// An amount of calendar time: "3 weeks", "1 year 2 months", "an hour", "90 min", "10 workdays".
struct CalcDateAmount {
    var years = 0, months = 0, days = 0, workdays = 0
    var seconds = 0.0

    var hasTime: Bool { seconds != 0 }
    var isEmpty: Bool { years == 0 && months == 0 && days == 0 && workdays == 0 && seconds == 0 }

    static let units: [String: (Calendar.Component, Int)] = [
        "s": (.second, 1), "sec": (.second, 1), "secs": (.second, 1), "second": (.second, 1), "seconds": (.second, 1),
        "min": (.minute, 1), "mins": (.minute, 1), "minute": (.minute, 1), "minutes": (.minute, 1),
        "h": (.hour, 1), "hr": (.hour, 1), "hrs": (.hour, 1), "hour": (.hour, 1), "hours": (.hour, 1),
        "d": (.day, 1), "day": (.day, 1), "days": (.day, 1),
        "w": (.day, 7), "wk": (.day, 7), "wks": (.day, 7), "week": (.day, 7), "weeks": (.day, 7),
        "fortnight": (.day, 14), "fortnights": (.day, 14),
        "mo": (.month, 1), "mos": (.month, 1), "month": (.month, 1), "months": (.month, 1),
        "quarter": (.month, 3), "quarters": (.month, 3),
        "y": (.year, 1), "yr": (.year, 1), "yrs": (.year, 1), "year": (.year, 1), "years": (.year, 1),
        "decade": (.year, 10), "decades": (.year, 10), "century": (.year, 100), "centuries": (.year, 100),
        "workday": (.weekday, 1), "workdays": (.weekday, 1), "business day": (.weekday, 1),
        "business days": (.weekday, 1), "working day": (.weekday, 1), "working days": (.weekday, 1),
        "work day": (.weekday, 1), "work days": (.weekday, 1), "weekday": (.weekday, 1), "weekdays": (.weekday, 1),
    ]

    /// Reads `text`; with `bareDays`, a lone number counts days ("August 5 + 5").
    static func parse(_ input: String, bareDays: Bool = false) -> CalcDateAmount? {
        // "3weeks" → "3 weeks"; "and" and commas join parts.
        var spaced = ""
        var previous: Character?
        for c in input.lowercased() {
            if let p = previous, p.isASCIIDigit, c.isLetter { spaced.append(" ") }
            spaced.append(c == "," ? " " : c)
            previous = c
        }
        var words = spaced.split(separator: " ").map(String.init).filter { $0 != "and" }
        guard !words.isEmpty, words.count <= 12 else { return nil }
        if bareDays, words.count == 1, let n = Int(words[0]) {
            return CalcDateAmount(days: n)
        }
        var amount = CalcDateAmount()
        while !words.isEmpty {
            let numberWord = words.removeFirst()
            let value: Double
            switch numberWord {
            case "a", "an", "one": value = 1
            case "two": value = 2
            case "three": value = 3
            default:
                guard let n = Double(numberWord), n.isFinite, abs(n) < 1e7 else { return nil }
                value = n
            }
            guard !words.isEmpty else { return nil }
            var unitWord = words.removeFirst()
            if let next = words.first, units["\(unitWord) \(next)"] != nil {
                unitWord += " \(next)"
                words.removeFirst()
            }
            guard let (component, scale) = units[unitWord] else { return nil }
            let scaled = value * Double(scale)
            switch component {
            case .second: amount.seconds += scaled
            case .minute: amount.seconds += scaled * 60
            case .hour: amount.seconds += scaled * 3600
            case .day, .month, .year, .weekday:
                if scaled != scaled.rounded() {
                    // "1.5 days" → hours; fractional months and years aren't calendar amounts.
                    guard component == .day else { return nil }
                    amount.seconds += scaled * 86400
                    continue
                }
                let whole = Int(scaled)
                switch component {
                case .day: amount.days += whole
                case .month: amount.months += whole
                case .year: amount.years += whole
                default: amount.workdays += whole
                }
            default: return nil
            }
        }
        return amount.isEmpty ? nil : amount
    }

    func negated() -> CalcDateAmount {
        CalcDateAmount(years: -years, months: -months, days: -days, workdays: -workdays, seconds: -seconds)
    }

    /// `date` moved by this amount (workdays skip Saturdays and Sundays).
    func apply(to date: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.year = years
        components.month = months
        components.day = days
        guard var result = calendar.date(byAdding: components, to: date) else { return nil }
        if workdays != 0 {
            var remaining = abs(workdays)
            let step = workdays > 0 ? 1 : -1
            while remaining > 0 {
                guard let next = calendar.date(byAdding: .day, value: step, to: result) else { return nil }
                result = next
                if !calendar.isDateInWeekend(result) { remaining -= 1 }
            }
        }
        return result.addingTimeInterval(seconds)
    }

    /// "3 weeks", "1 year, 2 months", "10 workdays".
    func text(format: CalcFormat) -> String {
        var parts: [String] = []
        func add(_ n: Int, _ name: String) {
            guard n != 0 else { return }
            parts.append("\(format.integer(abs(n))) \(name)\(abs(n) == 1 ? "" : "s")")
        }
        add(years, "year")
        add(months, "month")
        if days != 0, days % 7 == 0 { add(days / 7, "week") } else { add(days, "day") }
        add(workdays, "workday")
        if seconds != 0 { parts.append(CalcConversion.timespan(abs(seconds), format: format)) }
        return parts.joined(separator: ", ")
    }
}

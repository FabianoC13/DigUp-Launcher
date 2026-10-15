import Foundation

/// Date answers: countdowns ("days until christmas", "weeks until dec 25", "workdays until friday"), elapsed time
/// ("days since jan 1 2020", "days between march 1 and june 30"), arithmetic ("today + 3 weeks", "August 5 + 5",
/// "monday in 2 weeks", "date in 30 days", "35 days ago", "3 months from today"), weekdays ("what day is
/// 2027-03-14"), week numbers, Unix time ("unix 1700000000", "now in unix"), ISO 8601 timestamps, and work time
/// ("workhours in 2023", "workdays in march"). A date on its own ("dec 25", "tomorrow") isn't a question.
public enum CalcDates {
    public static func answer(_ input: String, env: CalcEnvironment) -> CalcAnswer? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        if let found = iso8601(trimmed, env: env) { return found }
        let text = CalcText.clean(trimmed).replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(in: .whitespaces)
        let dates = CalcDates.Context(env: env)
        return dates.unix(text) ?? dates.week(text) ?? dates.weekday(text) ?? dates.work(text)
            ?? dates.countdown(text) ?? dates.between(text) ?? dates.since(text) ?? dates.relative(text)
            ?? dates.arithmetic(text)
    }

    /// "2024-03-15T14:30:00Z", "2024-03-15T14:30:00+02:00", "2024-03-15T14:30:00.250Z" → local time.
    static func iso8601(_ text: String, env: CalcEnvironment) -> CalcAnswer? {
        guard text.count >= 16, !text.contains(" "), text.first?.isASCIIDigit == true,
              let t = text.firstIndex(where: { $0 == "T" || $0 == "t" }), text.distance(from: text.startIndex, to: t) == 10
        else { return nil }
        let normalized = text.uppercased()
        var date: Date?
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let found = formatter.date(from: normalized) {
                date = found
                break
            }
        }
        if date == nil {
            // No zone: local time.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = env.timeZone
            for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
                formatter.dateFormat = pattern
                if let found = formatter.date(from: normalized) {
                    date = found
                    break
                }
            }
        }
        guard let date else { return nil }
        let local = CalcDateText.dateTime(date, zone: env.timeZone, locale: env.locale)
        let utc = CalcDateText.dateTime(date, zone: TimeZone(identifier: "UTC") ?? env.timeZone, locale: env.locale)
        return CalcAnswer(kind: .date, result: local, expression: text,
                          caption: "UTC: \(utc) · Unix \(Int(date.timeIntervalSince1970))",
                          alternatives: [CalcAlternative("UTC", utc),
                                         CalcAlternative("Unix", String(Int(date.timeIntervalSince1970)))])
    }

    struct Context {
        let env: CalcEnvironment
        var phrase: CalcDatePhrase { CalcDatePhrase(env: env) }
        var calendar: Calendar { env.calendar }
        var today: Date { calendar.startOfDay(for: env.now) }

        // MARK: Unix time

        func unix(_ text: String) -> CalcAnswer? {
            let nowForms = ["now in unix", "now to unix", "now as unix", "unix now", "unix time", "unix timestamp",
                            "current unix time", "unix time now", "epoch time", "epoch now", "now in epoch",
                            "timestamp now", "current timestamp"]
            if nowForms.contains(text) {
                let seconds = Int(env.now.timeIntervalSince1970)
                return CalcAnswer(kind: .date, result: String(seconds), expression: "Now in Unix time",
                                  caption: CalcDateText.dateTime(env.now, zone: env.timeZone, locale: env.locale),
                                  number: String(seconds),
                                  alternatives: [CalcAlternative("Milliseconds", String(seconds * 1000))])
            }
            var digits: String?
            if let rest = CalcText.dropAnyPrefix(["unix time", "unix timestamp", "unix", "epoch", "timestamp"], from: text) {
                digits = rest
            } else if let rest = CalcText.dropAnyPrefix(["from unix"], from: text) {
                digits = rest
            } else if let rest = CalcText.dropSuffix("unix", from: text) ?? CalcText.dropSuffix("in unix", from: text) {
                if !rest.allSatisfy(\.isASCIIDigit), let day = phrase.parse(
                    CalcText.dropSuffix("in", from: rest) ?? CalcText.dropSuffix("to", from: rest)
                        ?? CalcText.dropSuffix("as", from: rest) ?? rest) {
                    let seconds = Int(day.date.timeIntervalSince1970)
                    return CalcAnswer(kind: .date, result: String(seconds),
                                      expression: "\(describe(day)) in Unix time", number: String(seconds))
                }
                digits = rest
            }
            guard let digits, (1...13).contains(digits.count), digits.allSatisfy(\.isASCIIDigit),
                  let value = Double(digits) else { return nil }
            // 13 digits are milliseconds.
            let seconds = digits.count >= 12 ? value / 1000 : value
            let date = Date(timeIntervalSince1970: seconds)
            let utc = CalcDateText.dateTime(date, zone: TimeZone(identifier: "UTC") ?? env.timeZone, locale: env.locale)
            return CalcAnswer(kind: .date, result: CalcDateText.dateTime(date, zone: env.timeZone, locale: env.locale),
                              expression: "Unix time \(digits)", caption: "UTC: \(utc) · \(relative(date))",
                              alternatives: [CalcAlternative("ISO 8601", ISO8601DateFormatter().string(from: date))])
        }

        // MARK: Weeks and weekdays

        func week(_ text: String) -> CalcAnswer? {
            let current = ["week number", "week no", "week #", "what week is it", "which week is it", "current week",
                           "week of year", "week of the year", "what week number is it", "current week number"]
            var day: CalcDay?
            if current.contains(text) {
                day = CalcDay(date: today)
            } else if let rest = CalcText.dropAnyPrefix(["week number of", "week number for", "week number",
                                                         "what week is", "week of"], from: text) {
                day = phrase.parse(rest)
            } else if let rest = CalcText.dropSuffix("week number", from: text) {
                day = phrase.parse(rest)
            }
            guard let day else { return nil }
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = env.timeZone
            iso.locale = env.locale
            let number = iso.component(.weekOfYear, from: day.date)
            let year = iso.component(.yearForWeekOfYear, from: day.date)
            var caption = "ISO week of \(CalcDateText.fullDate(day.date, zone: env.timeZone, locale: env.locale))"
            if let interval = iso.dateInterval(of: .weekOfYear, for: day.date),
               let last = iso.date(byAdding: .day, value: 6, to: interval.start) {
                let short = { CalcDateText.string($0, template: "MMMd", zone: env.timeZone, locale: env.locale) }
                caption += " · \(short(interval.start)) – \(short(last)) \(year)"
            }
            return CalcAnswer(kind: .date, result: "Week \(number)", expression: "Week number of \(describe(day))",
                              caption: caption, copyText: String(number), number: String(number))
        }

        func weekday(_ text: String) -> CalcAnswer? {
            guard let rest = CalcText.dropAnyPrefix(
                ["what day of the week is", "what day of the week was", "what day of week is", "what weekday is",
                 "what weekday was", "what day is", "what day was", "which day is", "which day was", "day of the week for",
                 "day of week for", "day of the week", "day of week", "weekday of", "weekday for"], from: text)
            else { return nil }
            let target = rest == "it" || rest == "it today" ? "today" : rest
            guard let day = phrase.parse(target) else { return nil }
            let name = CalcDateText.string(day.date, template: "EEEE", zone: env.timeZone, locale: env.locale)
            return CalcAnswer(kind: .date, result: name, expression: "Day of the week of \(describe(day))",
                              caption: "\(CalcDateText.fullDate(day.date, zone: env.timeZone, locale: env.locale)) · "
                                + relative(day.date))
        }

        // MARK: Work time

        /// "workhours in 2023", "workdays in march", "business days this month".
        func work(_ text: String) -> CalcAnswer? {
            let hourForms = ["workhours", "work hours", "working hours", "business hours"]
            let dayForms = ["workdays", "work days", "working days", "business days", "weekdays"]
            var hours = false
            var rest: String?
            for form in hourForms + dayForms {
                if let found = CalcText.dropPrefix(form, from: text) {
                    rest = CalcText.dropAnyPrefix(["in", "this", "for"], from: found).map {
                        found.hasPrefix("this") ? "this \($0)" : $0
                    } ?? found
                    hours = hourForms.contains(form)
                    break
                }
            }
            guard let rest, !rest.isEmpty, let interval = period(rest) else { return nil }
            var count = 0
            var day = interval.start
            while day < interval.end {
                if !calendar.isDateInWeekend(day) { count += 1 }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            let label = periodName(rest, interval: interval)
            let format = env.format
            if hours {
                return CalcAnswer(kind: .date, result: "\(format.integer(count * 8)) hours",
                                  expression: "Work hours in \(label)",
                                  caption: "\(format.integer(count)) workdays × 8 hours (Monday to Friday, "
                                    + "holidays not counted)", number: String(count * 8))
            }
            return CalcAnswer(kind: .date, result: "\(format.integer(count)) workdays",
                              expression: "Workdays in \(label)",
                              caption: "Monday to Friday, holidays not counted", number: String(count))
        }

        /// "2023", "this year", "next year", "march", "march 2027", "this month", "next month".
        func period(_ text: String) -> DateInterval? {
            let year = calendar.component(.year, from: today)
            switch text {
            case "this year", "year": return calendar.dateInterval(of: .year, for: today)
            case "next year": return calendar.date(byAdding: .year, value: 1, to: today).flatMap {
                calendar.dateInterval(of: .year, for: $0) }
            case "this month", "month": return calendar.dateInterval(of: .month, for: today)
            case "next month": return calendar.date(byAdding: .month, value: 1, to: today).flatMap {
                calendar.dateInterval(of: .month, for: $0) }
            default: break
            }
            if text.count == 4, let y = Int(text), y > 1000,
               let start = calendar.date(from: DateComponents(year: y, month: 1, day: 1)) {
                return calendar.dateInterval(of: .year, for: start)
            }
            let words = text.split(separator: " ").map(String.init)
            guard let month = words.first.flatMap({ CalcDatePhrase.months[$0] }), words.count <= 2 else { return nil }
            let y = words.count == 2 ? Int(words[1]) : year
            guard let y, let start = calendar.date(from: DateComponents(year: y, month: month, day: 1)) else { return nil }
            return calendar.dateInterval(of: .month, for: start)
        }

        func periodName(_ text: String, interval: DateInterval) -> String {
            if text.count == 4, Int(text) != nil { return text }
            return CalcDateText.string(interval.start, template: text.contains("year") ? "yyyy" : "MMMMyyyy",
                                       zone: env.timeZone, locale: env.locale)
        }

        // MARK: Countdowns and spans

        enum SpanUnit: String {
            case days, weeks, months, years, hours, minutes, seconds, workdays

            /// Hours, minutes and seconds count from this moment; the others from today.
            var countsTime: Bool { self == .hours || self == .minutes || self == .seconds }
        }

        static let spanUnits: [(String, SpanUnit)] = [
            ("days", .days), ("day", .days), ("weeks", .weeks), ("months", .months), ("years", .years),
            ("hours", .hours), ("minutes", .minutes), ("mins", .minutes), ("seconds", .seconds),
            ("workdays", .workdays), ("work days", .workdays), ("business days", .workdays),
            ("working days", .workdays), ("weekdays", .workdays), ("sleeps", .days), ("nights", .days),
            ("time", .days),
        ]

        /// The unit a question starts with ("how many days …", "weeks …"), and the rest.
        func spanUnit(_ text: String) -> (SpanUnit, String)? {
            let rest = CalcText.dropAnyPrefix(["how many", "how long", "number of"], from: text) ?? text
            if let after = CalcText.dropAnyPrefix(["until", "till", "til", "before", "since", "countdown to"], from: rest) {
                return (.days, rest.hasPrefix("since") ? "since " + after : "until " + after)
            }
            for (word, unit) in Self.spanUnits {
                if let after = CalcText.dropPrefix(word, from: rest) {
                    return (unit, CalcText.dropAnyPrefix(["left", "remaining", "are there", "is it", "has it been"],
                                                         from: after) ?? after)
                }
            }
            return nil
        }

        /// "days until christmas", "weeks till dec 25", "hours until new year", "days left in the year".
        func countdown(_ text: String) -> CalcAnswer? {
            guard let (unit, rest) = spanUnit(text) else { return nil }
            var target: CalcDay?
            if let after = CalcText.dropAnyPrefix(["until", "till", "til", "to", "before"], from: rest) {
                target = phrase.parse(after, direction: .next)
            } else if let after = CalcText.dropAnyPrefix(["in the", "in this", "in", "this"], from: rest) {
                target = phrase.parse("end of \(after)", direction: .next)
            }
            guard let target else { return nil }
            return span(from: CalcDay(date: unit.countsTime ? env.now : today, isNow: true), to: target, unit: unit,
                        verb: "until")
        }

        /// "days since jan 1 2020", "how long since christmas".
        func since(_ text: String) -> CalcAnswer? {
            guard let (unit, rest) = spanUnit(text), let after = CalcText.dropPrefix("since", from: rest),
                  let start = phrase.parse(after, direction: .past) else { return nil }
            return span(from: start, to: CalcDay(date: unit.countsTime ? env.now : today, isNow: true), unit: unit,
                        verb: "since")
        }

        /// "days between march 1 and june 30", "days from jan 1 to dec 25".
        func between(_ text: String) -> CalcAnswer? {
            guard let (unit, rest) = spanUnit(text),
                  let after = CalcText.dropAnyPrefix(["between", "from"], from: rest) else { return nil }
            for joiner in [" and ", " to ", " until ", " till "] {
                guard let range = after.range(of: joiner),
                      let start = phrase.parse(String(after[..<range.lowerBound])),
                      let end = phrase.parse(String(after[range.upperBound...])) else { continue }
                return span(from: start, to: end, unit: unit, verb: "between")
            }
            return nil
        }

        func span(from start: CalcDay, to end: CalcDay, unit: SpanUnit, verb: String) -> CalcAnswer? {
            let format = env.format
            let result: String
            var number: Double?
            switch unit {
            case .days, .weeks:
                let a = calendar.startOfDay(for: start.date), b = calendar.startOfDay(for: end.date)
                guard let days = calendar.dateComponents([.day], from: a, to: b).day else { return nil }
                if unit == .days {
                    result = "\(format.integer(abs(days))) \(abs(days) == 1 ? "day" : "days")"
                    number = Double(days)
                } else {
                    let weeks = Double(days) / 7
                    result = "\(format.quantity(abs(weeks), significant: 4)) \(abs(weeks) == 1 ? "week" : "weeks")"
                    number = weeks
                }
            case .months, .years:
                let parts: Set<Calendar.Component> = unit == .years ? [.year, .month, .day] : [.month, .day]
                let components = calendar.dateComponents(parts, from: start.date, to: end.date)
                let amount = CalcDateAmount(years: components.year ?? 0, months: components.month ?? 0,
                                            days: components.day ?? 0)
                let text = amount.text(format: format)
                result = text.isEmpty ? "0 days" : text.replacingOccurrences(of: "-", with: "")
            case .hours, .minutes, .seconds:
                let seconds = end.date.timeIntervalSince(start.date)
                let divisor: Double = unit == .hours ? 3600 : (unit == .minutes ? 60 : 1)
                let value = seconds / divisor
                result = "\(format.integer(Int(abs(value).rounded(.down)))) \(unit.rawValue)"
                number = value.rounded(.towardZero)
            case .workdays:
                var count = 0
                var day = calendar.startOfDay(for: min(start.date, end.date))
                let stop = calendar.startOfDay(for: max(start.date, end.date))
                while day < stop {
                    if !calendar.isDateInWeekend(day) { count += 1 }
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
                result = "\(format.integer(count)) \(count == 1 ? "workday" : "workdays")"
                number = Double(count)
            }
            let past = end.date < start.date && verb == "until"
            let endText = CalcDateText.fullDate(end.date, zone: env.timeZone, locale: env.locale)
            let startText = CalcDateText.fullDate(start.date, zone: env.timeZone, locale: env.locale)
            let unitName = unit.rawValue.prefix(1).uppercased() + unit.rawValue.dropFirst()
            let expression: String
            let caption: String
            switch verb {
            case "until":
                expression = "\(unitName) until \(describe(end))"
                caption = past ? "\(endText) was \(result) ago" : "Until \(endText)"
            case "since":
                expression = "\(unitName) since \(describe(start))"
                caption = "Since \(startText)"
            default:
                expression = "\(unitName) between \(describe(start)) and \(describe(end))"
                caption = "\(startText) → \(endText)"
            }
            var extra = ""
            if unit == .days, let days = number, abs(days) >= 14 {
                let weeks = Int(abs(days)) / 7, rest = Int(abs(days)) % 7
                extra = " · \(weeks) weeks" + (rest > 0 ? ", \(rest) \(rest == 1 ? "day" : "days")" : "")
            }
            return CalcAnswer(kind: .date, result: past ? "\(result) ago" : result, expression: expression,
                              caption: caption + extra, copyText: result,
                              number: number.map { format.raw(abs($0)) })
        }

        // MARK: Moving dates

        /// "in 3 weeks", "date in 30 days", "35 days ago", "3 months from today", "2 weeks after christmas",
        /// "monday in 2 weeks".
        func relative(_ text: String) -> CalcAnswer? {
            if let rest = CalcText.dropAnyPrefix(["date in", "what date is it in", "what's the date in",
                                                  "whats the date in", "what date is in", "day in", "in"], from: text),
               let amount = CalcDateAmount.parse(rest) {
                return moved(CalcDay(date: amount.hasTime ? env.now : today, isNow: amount.hasTime), by: amount,
                             expression: "In \(amount.text(format: env.format))")
            }
            if let rest = CalcText.dropSuffix("ago", from: text), let amount = CalcDateAmount.parse(rest) {
                return moved(CalcDay(date: amount.hasTime ? env.now : today, isNow: amount.hasTime),
                             by: amount.negated(), expression: "\(amount.text(format: env.format)) ago")
            }
            for (word, sign) in [(" from ", 1), (" after ", 1), (" before ", -1), (" later", 1)] {
                guard let range = text.range(of: word), let amount = CalcDateAmount.parse(String(text[..<range.lowerBound]))
                else { continue }
                var base = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if base.isEmpty || base == "now" { base = amount.hasTime ? "now" : "today" }
                guard let day = phrase.parse(base) else { continue }
                let expression = "\(amount.text(format: env.format)) \(word.trimmingCharacters(in: .whitespaces)) "
                    + describe(day)
                return moved(day, by: sign > 0 ? amount : amount.negated(), expression: expression)
            }
            // "monday in 2 weeks", "christmas in 2 years".
            if let range = text.range(of: " in ", options: .backwards),
               let day = phrase.parse(String(text[..<range.lowerBound])),
               let amount = CalcDateAmount.parse(String(text[range.upperBound...])) {
                return moved(day, by: amount, expression: "\(describe(day)) + \(amount.text(format: env.format))")
            }
            return nil
        }

        /// "today + 3 weeks", "now + 3 hours", "August 5 + 5", "christmas - 10 days", "dec 25 plus 2 weeks".
        func arithmetic(_ text: String) -> CalcAnswer? {
            for (word, sign) in [(" + ", 1), (" - ", -1), (" plus ", 1), (" minus ", -1)] {
                guard let range = text.range(of: word, options: .backwards),
                      let day = phrase.parse(String(text[..<range.lowerBound]), direction: .thisYear),
                      let amount = CalcDateAmount.parse(String(text[range.upperBound...]), bareDays: true) else { continue }
                let symbol = sign > 0 ? "+" : "-"
                return moved(day, by: sign > 0 ? amount : amount.negated(),
                             expression: "\(describe(day)) \(symbol) \(amount.text(format: env.format))")
            }
            return nil
        }

        func moved(_ day: CalcDay, by amount: CalcDateAmount, expression: String) -> CalcAnswer? {
            guard let date = amount.apply(to: day.date, calendar: calendar) else { return nil }
            let showsTime = day.isNow || amount.hasTime
            let result = showsTime ? CalcDateText.dateTime(date, zone: env.timeZone, locale: env.locale)
                : CalcDateText.fullDate(date, zone: env.timeZone, locale: env.locale)
            return CalcAnswer(kind: .date, result: result, expression: expression, caption: relative(date))
        }

        // MARK: Text

        /// "Christmas", "Today", "Monday, March 14, 2027" for expressions.
        func describe(_ day: CalcDay) -> String {
            if let label = day.label { return label }
            if day.isNow { return "Now" }
            let date = calendar.startOfDay(for: day.date)
            if date == today { return "Today" }
            return CalcDateText.string(date, template: "EEEMMMdyyyy", zone: env.timeZone, locale: env.locale)
        }

        /// "Today", "Tomorrow", "In 14 days", "3 days ago", "In 3 hours".
        func relative(_ date: Date) -> String {
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
            switch days {
            case 0:
                let minutes = Int(date.timeIntervalSince(env.now) / 60)
                if abs(minutes) >= 60 { return minutes > 0 ? "Today, in \(minutes / 60) hours" : "Today, \(-minutes / 60) hours ago" }
                return "Today"
            case 1: return "Tomorrow"
            case -1: return "Yesterday"
            default:
                let n = env.format.integer(abs(days))
                return days > 0 ? "In \(n) days" : "\(n) days ago"
            }
        }
    }
}

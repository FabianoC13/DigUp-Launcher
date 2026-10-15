import Foundation

/// A day or moment named in a question.
struct CalcDay {
    /// Midnight of the day in the environment's zone, or the exact moment for "now".
    var date: Date
    var isNow = false
    /// A holiday's name ("Christmas"), shown in captions.
    var label: String?
}

/// Reads the dates people type: today/tomorrow/yesterday/now, weekdays ("next monday"), "dec 25", "25 December 2027",
/// "2027-03-14", "14.03.2027", "3/14/2027" (in the locale's order), holidays (Christmas, Easter, Thanksgiving…), and
/// "end of month/quarter/year".
struct CalcDatePhrase {
    /// Where a date without a year goes: the coming twelve months, the past twelve, or this calendar year.
    enum Direction { case next, past, thisYear }

    let env: CalcEnvironment
    var calendar: Calendar { env.calendar }

    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5,
        "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3, "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5, "friday": 6, "fri": 6, "saturday": 7, "sat": 7,
    ]

    var today: Date { calendar.startOfDay(for: env.now) }

    func parse(_ input: String, direction: Direction = .next) -> CalcDay? {
        var text = CalcText.clean(input).replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "’", with: "'")
        text = text.split(separator: " ").filter { $0 != "the" && $0 != "of" && $0 != "on" }.joined(separator: " ")
        guard !text.isEmpty, text.count <= 40 else { return nil }
        switch text {
        case "now", "right now": return CalcDay(date: env.now, isNow: true)
        case "today", "tonight": return CalcDay(date: today)
        case "tomorrow", "tmrw", "tmr": return day(byAdding: 1)
        case "yesterday": return day(byAdding: -1)
        case "day after tomorrow": return day(byAdding: 2)
        case "day before yesterday": return day(byAdding: -2)
        default: break
        }
        if let found = holiday(text, direction: direction) { return found }
        if let found = weekday(text) { return found }
        if let found = numeric(text) { return found }
        return named(text, direction: direction)
    }

    private func day(byAdding days: Int) -> CalcDay? {
        calendar.date(byAdding: .day, value: days, to: today).map { CalcDay(date: $0) }
    }

    /// "monday", "next friday", "last sunday", "this wednesday".
    private func weekday(_ text: String) -> CalcDay? {
        let words = text.split(separator: " ").map(String.init)
        guard (1...2).contains(words.count), let target = Self.weekdays[words[words.count - 1]] else { return nil }
        let modifier = words.count == 2 ? words[0] : ""
        guard ["", "this", "next", "coming", "last", "previous", "past"].contains(modifier) else { return nil }
        let current = calendar.component(.weekday, from: today)
        var delta = (target - current + 7) % 7
        switch modifier {
        case "next": if delta == 0 { delta = 7 }
        case "last", "previous", "past": delta = delta == 0 ? -7 : delta - 7
        default: break
        }
        return day(byAdding: delta)
    }

    /// "2027-03-14", "2027/03/14", "14.03.2027", "3/14/2027" or "14/3/2027" (the locale's order), "3/14".
    private func numeric(_ text: String) -> CalcDay? {
        guard !text.contains(" "), text.first?.isASCIIDigit == true else { return nil }
        let separator: Character
        if text.contains("-") {
            separator = "-"
        } else if text.contains("/") {
            separator = "/"
        } else if text.contains(".") {
            separator = "."
        } else {
            return nil
        }
        let parts = text.split(separator: separator, omittingEmptySubsequences: false).map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        let pieces = text.split(separator: separator)
        if numbers.count == 3, pieces[0].count == 4 {
            return make(year: numbers[0], month: numbers[1], day: numbers[2])
        }
        guard separator != "-" else { return nil }
        let monthFirst = separator == "/" && localeIsMonthFirst
        if numbers.count == 3 {
            var year = numbers[2]
            if pieces[2].count == 2 { year += 2000 }
            guard pieces[2].count == 4 || pieces[2].count == 2 else { return nil }
            return monthFirst ? make(year: year, month: numbers[0], day: numbers[1])
                : make(year: year, month: numbers[1], day: numbers[0])
        }
        if numbers.count == 2, separator == "/" {
            let year = calendar.component(.year, from: today)
            return monthFirst ? make(year: year, month: numbers[0], day: numbers[1])
                : make(year: year, month: numbers[1], day: numbers[0])
        }
        return nil
    }

    private var localeIsMonthFirst: Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: env.locale) ?? "M/d/y"
        return pattern.firstIndex(of: "M").map { m in pattern.firstIndex(of: "d").map { m < $0 } ?? true } ?? true
    }

    /// "dec 25", "december 25th 2027", "25 dec", "25th december 2027", "march 2027".
    private func named(_ text: String, direction: Direction) -> CalcDay? {
        let words = text.split(separator: " ").map(String.init)
        guard (1...3).contains(words.count) else { return nil }
        var month: Int?, dayNumber: Int?, year: Int?
        for word in words {
            if let m = Self.months[word], month == nil {
                month = m
            } else if let n = Self.ordinal(word) {
                if word.count == 4, year == nil, n >= 1000 {
                    year = n
                } else if dayNumber == nil, n >= 1, n <= 31 {
                    dayNumber = n
                } else if year == nil, n >= 1000 {
                    year = n
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        guard let month else { return nil }
        guard dayNumber != nil || year != nil else { return nil }
        let currentYear = calendar.component(.year, from: today)
        guard var found = make(year: year ?? currentYear, month: month, day: dayNumber ?? 1) else { return nil }
        if year == nil {
            found = adjust(found, direction: direction) { make(year: currentYear + $0, month: month, day: dayNumber ?? 1) }
        }
        return found
    }

    /// Moves a day without a year into the coming (or the past) twelve months.
    private func adjust(_ day: CalcDay, direction: Direction, yearOffset: (Int) -> CalcDay?) -> CalcDay {
        switch direction {
        case .next where day.date < today: return yearOffset(1) ?? day
        case .past where day.date > today: return yearOffset(-1) ?? day
        default: return day
        }
    }

    /// "25", "25th", "1st", "2nd", "3rd".
    static func ordinal(_ word: String) -> Int? {
        var digits = word
        for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) && digits.count > 2 {
            digits.removeLast(2)
            break
        }
        guard digits.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(digits)
    }

    func make(year: Int, month: Int, day: Int, label: String? = nil) -> CalcDay? {
        guard (1...12).contains(month), (1...31).contains(day), (1...9999).contains(year) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil }
        return CalcDay(date: date, label: label)
    }

    // MARK: Holidays

    private func holiday(_ text: String, direction: Direction) -> CalcDay? {
        let key = text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "day", with: "")
            .replacingOccurrences(of: " ", with: "")
        let currentYear = calendar.component(.year, from: today)
        let make: (Int) -> CalcDay?
        switch key {
        case "christmas", "xmas", "chrismas":
            make = { self.make(year: $0, month: 12, day: 25, label: "Christmas") }
        case "christmaseve", "xmaseve":
            make = { self.make(year: $0, month: 12, day: 24, label: "Christmas Eve") }
        case "boxing":
            make = { self.make(year: $0, month: 12, day: 26, label: "Boxing Day") }
        case "newyear", "newyears", "nextyear":
            return self.make(year: currentYear + 1, month: 1, day: 1, label: "New Year's Day")
        case "newyearseve", "newyeareve", "nye", "endyear", "yearend", "endthisyear":
            make = { self.make(year: $0, month: 12, day: 31, label: "New Year's Eve") }
        case "halloween":
            make = { self.make(year: $0, month: 10, day: 31, label: "Halloween") }
        case "valentines", "valentine", "stvalentines":
            make = { self.make(year: $0, month: 2, day: 14, label: "Valentine's Day") }
        case "stpatricks", "saintpatricks", "stpaddys":
            make = { self.make(year: $0, month: 3, day: 17, label: "St. Patrick's Day") }
        case "aprilfools":
            make = { self.make(year: $0, month: 4, day: 1, label: "April Fools' Day") }
        case "independence", "4thjuly", "fourthjuly", "july4th", "july4":
            make = { self.make(year: $0, month: 7, day: 4, label: "Independence Day") }
        case "easter", "eastersun":
            make = { self.easter($0) }
        case "thanksgiving":
            make = { self.nthWeekday(year: $0, month: 11, weekday: 5, n: 4, label: "Thanksgiving") }
        case "blackfri":
            make = {
                self.nthWeekday(year: $0, month: 11, weekday: 5, n: 4, label: "Black Friday").flatMap {
                    self.calendar.date(byAdding: .day, value: 1, to: $0.date).map { CalcDay(date: $0, label: "Black Friday") }
                }
            }
        case "endmonth", "monthend", "endthismonth":
            guard let interval = calendar.dateInterval(of: .month, for: today),
                  let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
            return CalcDay(date: last, label: "End of month")
        case "endquarter", "quarterend", "endthisquarter", "endq":
            let month = calendar.component(.month, from: today)
            let quarterEnd = ((month - 1) / 3 + 1) * 3
            guard let first = self.make(year: currentYear, month: quarterEnd, day: 1),
                  let interval = calendar.dateInterval(of: .month, for: first.date),
                  let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
            return CalcDay(date: last, label: "End of quarter")
        case "endweek", "weekend", "thisweekend":
            let current = calendar.component(.weekday, from: today)
            return day(byAdding: (7 - current + 7) % 7).map { CalcDay(date: $0.date, label: "The weekend") }
        default:
            return nil
        }
        guard let this = make(currentYear) else { return nil }
        switch direction {
        case .next where this.date < today: return make(currentYear + 1)
        case .past where this.date > today: return make(currentYear - 1)
        default: return this
        }
    }

    /// Easter Sunday (the anonymous Gregorian algorithm).
    func easter(_ year: Int) -> CalcDay? {
        let a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, day = (h + l - 7 * m + 114) % 31 + 1
        return make(year: year, month: month, day: day, label: "Easter")
    }

    /// The `n`th `weekday` (1 = Sunday) of a month.
    func nthWeekday(year: Int, month: Int, weekday: Int, n: Int, label: String) -> CalcDay? {
        guard let first = make(year: year, month: month, day: 1) else { return nil }
        let firstWeekday = calendar.component(.weekday, from: first.date)
        let day = 1 + (weekday - firstWeekday + 7) % 7 + (n - 1) * 7
        return make(year: year, month: month, day: day, label: label)
    }
}

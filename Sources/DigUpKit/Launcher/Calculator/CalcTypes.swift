import Foundation

/// Whether trigonometry reads and returns degrees or radians when a number doesn't say ("sin 30", "asin 1").
public enum CalcAngleMode: String, Codable, Sendable, CaseIterable {
    case degrees, radians
}

/// What kind of question an answer is for; the launcher shows it as the row's tag.
public enum CalcAnswerKind: String, Codable, Sendable {
    case math, unit, currency, timeZone, date, base, color

    /// The row's accessory text.
    public var label: String {
        switch self {
        case .math: "Calculator"
        case .unit: "Conversion"
        case .currency: "Currency"
        case .timeZone: "Time Zone"
        case .date: "Date"
        case .base: "Number Base"
        case .color: "Color"
        }
    }
}

/// Everything an evaluation depends on besides the question, so tests can pin the clock, the zone and the rates.
public struct CalcEnvironment: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var locale: Locale
    public var angleMode: CalcAngleMode
    /// Exchange rates, nil until the first download (or the cache) is read.
    public var rates: CalcRates?
    /// The currency "100 eur" converts to when no target is named (ISO code).
    public var defaultCurrency: String
    /// Pixels per rem/em for "2rem in px".
    public var remBase: Double
    /// Whether "#ff8800", "rgb(…)" and the like show a color answer.
    public var colorsEnabled: Bool

    public init(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current,
                angleMode: CalcAngleMode = .degrees, rates: CalcRates? = nil, defaultCurrency: String? = nil,
                remBase: Double = 16, colorsEnabled: Bool = true) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self.angleMode = angleMode
        self.rates = rates
        self.defaultCurrency = (defaultCurrency ?? locale.currency?.identifier ?? "USD").uppercased()
        self.remBase = remBase
        self.colorsEnabled = colorsEnabled
    }

    /// A Gregorian calendar in the environment's zone and locale.
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    public var format: CalcFormat { CalcFormat(locale: locale) }
}

/// One answer to show in the launcher.
public struct CalcAnswer: Sendable, Equatable {
    public var kind: CalcAnswerKind
    /// The formatted answer, shown big ("10", "6.21371 mi", "Tomorrow 2:00 AM · +9h").
    public var result: String
    /// The question as the calculator understood it ("20% of 50", "10 km in mi").
    public var expression: String
    /// More about the answer for the preview: the full date, the rate used, other bases…
    public var caption: String?
    /// What "Copy Answer" copies when it should differ from `result` ("2:00 AM" without the offset).
    public var copyText: String
    /// The bare number when there is one ("1234.5" with the locale's decimal mark, no grouping), for "Copy Number" and
    /// putting the answer back in the search field.
    public var number: String?
    /// Other ways to write the answer, each a (label, value) pair shown in the preview and copyable.
    public var alternatives: [CalcAlternative]
    /// The color, for color answers.
    public var color: CalcColor?

    public init(kind: CalcAnswerKind, result: String, expression: String, caption: String? = nil,
                copyText: String? = nil, number: String? = nil, alternatives: [CalcAlternative] = [],
                color: CalcColor? = nil) {
        self.kind = kind
        self.result = result
        self.expression = expression
        self.caption = caption
        self.copyText = copyText ?? result
        self.number = number
        self.alternatives = alternatives
        self.color = color
    }
}

/// Another form of an answer ("Hex" → "0xFF").
public struct CalcAlternative: Sendable, Equatable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Text helpers shared by the parsers.
enum CalcText {
    /// Lowercased (unless asked not to), curly quotes and odd dashes made plain, runs of spaces as one, trimmed.
    static func clean(_ text: String, lowercased: Bool = true) -> String {
        var out = ""
        var lastSpace = true
        for character in lowercased ? text.lowercased() : text {
            var c = character
            switch c {
            case "’", "‘", "`": c = "'"
            case "“", "”": c = "\""
            case "−", "–", "—": c = "-"
            case "\u{00A0}", "\u{202F}", "\t", "\n": c = " "
            default: break
            }
            if c == " " {
                if lastSpace { continue }
                lastSpace = true
            } else {
                lastSpace = false
            }
            out.append(c)
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    /// `text` without `prefix` when it starts with it as whole words.
    static func dropPrefix(_ prefix: String, from text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        if rest.isEmpty { return "" }
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }

    /// `text` without `suffix` when it ends with it as whole words.
    static func dropSuffix(_ suffix: String, from text: String) -> String? {
        guard text.hasSuffix(suffix) else { return nil }
        let rest = text.dropLast(suffix.count)
        if rest.isEmpty { return "" }
        guard rest.last == " " else { return nil }
        return String(rest.dropLast())
    }

    /// The first prefix in `prefixes` that `text` starts with, and what follows it.
    static func dropAnyPrefix(_ prefixes: [String], from text: String) -> String? {
        for prefix in prefixes {
            if let rest = dropPrefix(prefix, from: text) { return rest }
        }
        return nil
    }

    /// Splits `text` at the last ` word ` from `separators` whose two sides are both non-empty, trying each such
    /// place from the right until `accept` takes one.
    static func splitLast<T>(_ text: String, separators: [String],
                             accept: (_ left: String, _ right: String) -> T?) -> T? {
        var places: [(Range<String.Index>, Int)] = []
        for separator in separators {
            let needle = " \(separator) "
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: needle, range: searchRange) {
                places.append((found, needle.count))
                searchRange = text.index(after: found.lowerBound)..<text.endIndex
            }
        }
        places.sort { $0.0.lowerBound > $1.0.lowerBound }
        for (range, _) in places {
            let left = String(text[..<range.lowerBound])
            let right = String(text[range.upperBound...])
            guard !left.isEmpty, !right.isEmpty else { continue }
            if let found = accept(left, right) { return found }
        }
        return nil
    }
}

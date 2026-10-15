import Foundation

/// An {argument} a snippet asks for before it's pasted.
public struct SnippetArgument: Equatable, Sendable {
    /// Its name, or "#1", "#2"… for unnamed ones: arguments with the same name share one value.
    public var key: String
    /// What the question shows ("name", "Argument 2").
    public var name: String
    public var defaultValue: String?
    /// The choices, when it's one of a few ("options=\"Hi,Hello\"").
    public var options: [String]

    public init(key: String, name: String, defaultValue: String? = nil, options: [String] = []) {
        self.key = key
        self.name = name
        self.defaultValue = defaultValue
        self.options = options
    }
}

/// What placeholders read from the world at expansion time. Tests pass fixed values.
public struct SnippetPlaceholderValues {
    public var now: Date
    public var calendar: Calendar
    public var locale: Locale
    public var timeZone: TimeZone
    /// The copied text at an offset: 0 is what's on the clipboard now, 1 the copy before (Clipboard History)…
    public var clipboard: (Int) -> String?
    /// The text selected in the app in front.
    public var selection: () -> String?
    /// Another snippet's text, by its name.
    public var snippet: (String) -> String?
    /// The values given for the {argument}s, by `SnippetArgument.key`.
    public var arguments: [String: String]
    public var uuid: () -> String

    public init(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current,
                timeZone: TimeZone = .current, clipboard: @escaping (Int) -> String? = { _ in nil },
                selection: @escaping () -> String? = { nil }, snippet: @escaping (String) -> String? = { _ in nil },
                arguments: [String: String] = [:], uuid: @escaping () -> String = { UUID().uuidString }) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.timeZone = timeZone
        self.clipboard = clipboard
        self.selection = selection
        self.snippet = snippet
        self.arguments = arguments
        self.uuid = uuid
    }
}

/// A snippet's text with its placeholders filled in.
public struct SnippetExpansion: Equatable, Sendable {
    public var text: String
    /// How many characters come after the {cursor} marker: the caret goes back that many (← presses) after pasting.
    /// Nil without a marker.
    public var charactersAfterCursor: Int?

    public init(text: String, charactersAfterCursor: Int? = nil) {
        self.text = text
        self.charactersAfterCursor = charactersAfterCursor
    }
}

/// Raycast's dynamic placeholders: `{clipboard}`, `{clipboard offset=1}`, `{date}`, `{time}`, `{datetime}`, `{day}`
/// (each with `offset="+3d -2h"`, `format="yyyy-MM-dd"` and `locale="fr-FR"`), `{uuid}`, `{cursor}`, `{selection}`,
/// `{snippet name="…"}` (one level deep) and `{argument name="…" default="…" options="a,b"}`, each optionally piped
/// through modifiers: `{clipboard | trim | uppercase}` (uppercase, lowercase, trim, percent-encode, json-stringify,
/// raw). Anything else in braces, or a placeholder it can't read, stays as typed.
public enum SnippetPlaceholders {
    /// The placeholders it knows, for the editor's help.
    public static let help: [(placeholder: String, meaning: String)] = [
        ("{clipboard}", "The text on the clipboard ({clipboard offset=1}: the copy before)"),
        ("{selection}", "The text selected in the app in front"),
        ("{date}", "Today's date ({date format=\"yyyy-MM-dd\"}, {date offset=\"+3d\"})"),
        ("{time}", "The time now"),
        ("{datetime}", "The date and the time"),
        ("{day}", "The day of the week"),
        ("{uuid}", "A new unique ID"),
        ("{cursor}", "Where the caret goes after pasting"),
        ("{argument name=\"name\"}", "Asks for a value when pasted (default=\"…\", options=\"a,b\")"),
        ("{snippet name=\"…\"}", "Another snippet's text"),
    ]

    static let names: Set<String> = ["clipboard", "date", "time", "datetime", "day", "uuid", "cursor", "selection",
                                     "snippet", "argument"]
    static let modifiers: Set<String> = ["uppercase", "lowercase", "trim", "percent-encode", "json-stringify", "raw"]

    /// A piece of a template: text as typed, or a placeholder.
    enum Token: Equatable {
        case literal(String)
        case placeholder(Placeholder)
    }

    struct Placeholder: Equatable {
        var name: String
        var attributes: [String: String]
        var modifiers: [String]
        /// Exactly as typed, braces included: what's left when it can't be filled.
        var source: String
    }

    // MARK: Expanding

    /// `template` with its placeholders filled in from `values`.
    public static func expand(_ template: String, values: SnippetPlaceholderValues) -> SnippetExpansion {
        var output = Output()
        var unnamed = 0
        append(template, to: &output, values: values, unnamed: &unnamed, embedding: true)
        return SnippetExpansion(text: output.before + (output.after ?? ""),
                                charactersAfterCursor: output.after.map(\.count))
    }

    /// The {argument}s the template asks for, in order, one per name (an embedded snippet's too).
    public static func arguments(in template: String, snippet: (String) -> String? = { _ in nil })
        -> [SnippetArgument] {
        var found: [SnippetArgument] = []
        var unnamed = 0
        func collect(_ text: String, embedding: Bool) {
            for case .placeholder(let placeholder) in tokens(text) {
                switch placeholder.name {
                case "argument":
                    let argument = self.argument(placeholder, unnamed: &unnamed)
                    if !found.contains(where: { $0.key == argument.key }) { found.append(argument) }
                case "snippet" where embedding:
                    if let name = placeholder.attributes["name"], let text = snippet(name) {
                        collect(text, embedding: false)
                    }
                default:
                    break
                }
            }
        }
        collect(template, embedding: true)
        return found
    }

    /// Whether the template asks for anything (arguments) or reads the world at all (otherwise it's plain text).
    public static func hasPlaceholders(_ template: String) -> Bool {
        tokens(template).contains { if case .placeholder = $0 { true } else { false } }
    }

    /// The text being built: before the {cursor}, and after it once there was one.
    private struct Output {
        var before = ""
        var after: String?

        mutating func append(_ text: String) {
            if after != nil { after! += text } else { before += text }
        }
    }

    private static func append(_ template: String, to output: inout Output, values: SnippetPlaceholderValues,
                               unnamed: inout Int, embedding: Bool) {
        for token in tokens(template) {
            switch token {
            case .literal(let text):
                output.append(text)
            case .placeholder(let placeholder):
                if placeholder.name == "cursor" {
                    // Only the first one counts; later markers just go away.
                    if output.after == nil { output.after = "" }
                    continue
                }
                if placeholder.name == "snippet" {
                    guard embedding, let name = placeholder.attributes["name"], let text = values.snippet(name) else {
                        output.append(placeholder.source)
                        continue
                    }
                    if placeholder.modifiers.allSatisfy({ $0 == "raw" }) {
                        append(text, to: &output, values: values, unnamed: &unnamed, embedding: false)
                    } else {
                        // Modifiers apply to the whole embedded text, so it's built on its own first.
                        var inner = Output()
                        append(text, to: &inner, values: values, unnamed: &unnamed, embedding: false)
                        output.append(apply(placeholder.modifiers, to: inner.before + (inner.after ?? "")))
                    }
                    continue
                }
                if let value = value(of: placeholder, values: values, unnamed: &unnamed) {
                    output.append(apply(placeholder.modifiers, to: value))
                } else {
                    output.append(placeholder.source)
                }
            }
        }
    }

    /// The text a placeholder stands for, or nil when it can't be read (a bad offset or locale).
    private static func value(of placeholder: Placeholder, values: SnippetPlaceholderValues,
                              unnamed: inout Int) -> String? {
        switch placeholder.name {
        case "clipboard":
            var offset = 0
            if let text = placeholder.attributes["offset"] {
                guard let number = Int(text), number >= 0 else { return nil }
                offset = number
            }
            return values.clipboard(offset) ?? ""
        case "selection":
            return values.selection() ?? ""
        case "uuid":
            return values.uuid()
        case "argument":
            let argument = argument(placeholder, unnamed: &unnamed)
            return values.arguments[argument.key] ?? argument.defaultValue ?? ""
        case "date", "time", "datetime", "day":
            return date(placeholder, values: values)
        default:
            return nil
        }
    }

    private static func argument(_ placeholder: Placeholder, unnamed: inout Int) -> SnippetArgument {
        let options = placeholder.attributes["options"].map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } ?? []
        if let name = placeholder.attributes["name"], !name.isEmpty {
            return SnippetArgument(key: name, name: name, defaultValue: placeholder.attributes["default"],
                                   options: options)
        }
        unnamed += 1
        return SnippetArgument(key: "#\(unnamed)", name: unnamed == 1 ? "Argument" : "Argument \(unnamed)",
                               defaultValue: placeholder.attributes["default"], options: options)
    }

    // MARK: Dates

    private static func date(_ placeholder: Placeholder, values: SnippetPlaceholderValues) -> String? {
        var date = values.now
        if let offset = placeholder.attributes["offset"] {
            guard let shifted = shift(date, by: offset, calendar: values.calendar) else { return nil }
            date = shifted
        }
        let formatter = DateFormatter()
        formatter.calendar = values.calendar
        formatter.timeZone = values.timeZone
        formatter.locale = values.locale
        if let identifier = placeholder.attributes["locale"] {
            guard isKnownLocale(identifier) else { return nil }
            formatter.locale = Locale(identifier: identifier)
        }
        if let format = placeholder.attributes["format"] {
            guard !format.isEmpty else { return nil }
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        switch placeholder.name {
        case "date":
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case "time":
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case "datetime":
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        default:
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        }
        return formatter.string(from: date)
    }

    private static let localeIdentifiers = Set(Locale.availableIdentifiers)

    /// "fr-FR", "en-US-u-hc-h23", "de": a locale the system has (its language, at least), extensions allowed.
    static func isKnownLocale(_ identifier: String) -> Bool {
        let base = (identifier.components(separatedBy: "-u-").first ?? identifier)
            .components(separatedBy: "@").first?.replacingOccurrences(of: "-", with: "_") ?? ""
        guard !base.isEmpty else { return false }
        if localeIdentifiers.contains(base) { return true }
        let language = base.components(separatedBy: "_").first ?? base
        return base == language && localeIdentifiers.contains(language)
    }

    /// `date` moved by an offset like "+3d", "-2h", "+2y +5M" (m minutes, h hours, d days, w weeks, M months,
    /// y years); nil when the offset can't be read.
    static func shift(_ date: Date, by offset: String, calendar: Calendar) -> Date? {
        var date = date
        let terms = offset.split(whereSeparator: { $0 == " " || $0 == "," })
        guard !terms.isEmpty else { return nil }
        for term in terms {
            var text = Substring(term)
            var sign = 1
            if text.first == "+" { text = text.dropFirst() } else if text.first == "-" { sign = -1; text = text.dropFirst() }
            guard let unit = text.last, let amount = Int(text.dropLast()) else { return nil }
            let component: Calendar.Component
            var value = amount * sign
            switch unit {
            case "m": component = .minute
            case "h": component = .hour
            case "d": component = .day
            case "w": component = .day; value *= 7
            case "M": component = .month
            case "y": component = .year
            default: return nil
            }
            guard let next = calendar.date(byAdding: component, value: value, to: date) else { return nil }
            date = next
        }
        return date
    }

    // MARK: Modifiers

    private static func apply(_ modifiers: [String], to value: String) -> String {
        var value = value
        for modifier in modifiers {
            switch modifier {
            case "uppercase": value = value.uppercased()
            case "lowercase": value = value.lowercased()
            case "trim": value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "percent-encode": value = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            case "json-stringify": value = jsonString(value)
            default: break   // raw: snippets have no default formatting to turn off
            }
        }
        return value
    }

    /// RFC 3986's unreserved characters: everything else is percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The text as a JSON string's contents, escaped, without the outer quotes.
    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8),
              text.count >= 2 else { return value }
        return String(text.dropFirst().dropLast())
    }

    // MARK: Parsing

    /// The template as literal text and placeholders. A brace that doesn't open a placeholder it knows stays text.
    static func tokens(_ template: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            if character == "{", let (placeholder, end) = placeholder(in: template, at: index) {
                if !literal.isEmpty {
                    tokens.append(.literal(literal))
                    literal = ""
                }
                tokens.append(.placeholder(placeholder))
                index = end
            } else {
                literal.append(character)
                index = template.index(after: index)
            }
        }
        if !literal.isEmpty { tokens.append(.literal(literal)) }
        return tokens
    }

    /// The placeholder that starts at `start` (a "{") and the index after its "}", or nil when it isn't one.
    private static func placeholder(in template: String, at start: String.Index)
        -> (Placeholder, String.Index)? {
        var index = template.index(after: start)
        var inQuotes = false
        var inner = ""
        while index < template.endIndex {
            let character = template[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, character == "{" || character == "\n" {
                return nil
            } else if !inQuotes, character == "}" {
                let end = template.index(after: index)
                guard let placeholder = parse(inner, source: String(template[start..<end])) else { return nil }
                return (placeholder, end)
            }
            inner.append(character)
            index = template.index(after: index)
        }
        return nil
    }

    /// "date offset=\"+3d\" | uppercase" → the placeholder, or nil for a name or modifier it doesn't know.
    private static func parse(_ inner: String, source: String) -> Placeholder? {
        let parts = split(inner, on: "|")
        guard let head = parts.first else { return nil }
        let words = split(head, on: " ").filter { !$0.isEmpty }
        guard let name = words.first, names.contains(name) else { return nil }
        var attributes: [String: String] = [:]
        for word in words.dropFirst() {
            guard let equals = word.firstIndex(of: "=") else { return nil }
            let key = String(word[..<equals])
            var value = String(word[word.index(after: equals)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { return nil }
            attributes[key] = value
        }
        let modifiers = parts.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        guard modifiers.allSatisfy(Self.modifiers.contains) else { return nil }
        return Placeholder(name: name, attributes: attributes, modifiers: modifiers, source: source)
    }

    /// `text` split on `separator` where it's outside double quotes (quotes are kept).
    private static func split(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" { inQuotes.toggle() }
            if character == separator, !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

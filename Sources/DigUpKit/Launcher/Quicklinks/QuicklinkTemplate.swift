import Foundation

/// A quicklink's link with its dynamic placeholders, Raycast's syntax:
///
/// - `{query}` or `{argument}`: what you type for it. `{argument name="to" default="en" options="en, fr"}` names one
///   (the same name shares one value), gives it a default (then it may be left empty) or a list to pick from.
/// - `{clipboard}`: the text on the clipboard.
/// - `{date}`, `{time}`, `{datetime}`, `{day}`: now, with `format="yyyy-MM-dd"`, `offset="+2d -3h"`, `locale="fr-FR"`.
/// - `{uuid}`: a new unique id.
/// - Modifiers after a bar, in order: `{query | trim | lowercase}`; `uppercase`, `lowercase`, `trim`,
///   `percent-encode`, `json-stringify`, `raw`.
///
/// Values are percent-encoded unless the token says `raw` (or encodes them itself), except in a file path, where they
/// go in as typed. Anything else in braces stays as written.
public struct QuicklinkTemplate: Equatable, Sendable {
    /// One value the quicklink asks for.
    public struct Argument: Equatable, Sendable {
        /// What it's filed under in `Values.arguments`: "query" for `{query}` and an unnamed `{argument}`, else its
        /// name.
        public let key: String
        /// Its name as written (nil when unnamed).
        public let label: String?
        public let defaultValue: String?
        /// A fixed list to pick from (empty: free text).
        public let options: [String]

        /// It must be given: there's no default to fall back on.
        public var isRequired: Bool { defaultValue == nil }
    }

    /// What a link is filled with.
    public struct Values: Sendable {
        /// Argument key → what was typed.
        public var arguments: [String: String]
        public var clipboard: String?
        public var date: Date
        public var calendar: Calendar
        public var locale: Locale
        public var makeUUID: @Sendable () -> String

        public init(arguments: [String: String] = [:], clipboard: String? = nil, date: Date = Date(),
                    calendar: Calendar = .current, locale: Locale = .current,
                    makeUUID: @escaping @Sendable () -> String = { UUID().uuidString }) {
            self.arguments = arguments
            self.clipboard = clipboard
            self.date = date
            self.calendar = calendar
            self.locale = locale
            self.makeUUID = makeUUID
        }
    }

    struct Token: Equatable, Sendable {
        let name: String
        let attributes: [String: String]
        let modifiers: [String]
    }

    enum Piece: Equatable, Sendable {
        case text(String)
        case token(Token)
    }

    static let tokenNames: Set<String> = ["query", "argument", "clipboard", "date", "time", "datetime", "day", "uuid"]

    public let link: String
    let pieces: [Piece]
    /// The values it asks for, in the order they first appear.
    public let arguments: [Argument]

    public init(_ link: String) {
        self.link = link
        pieces = Self.parse(link)
        var arguments: [Argument] = []
        for case .token(let token) in pieces where token.name == "query" || token.name == "argument" {
            let key = Self.argumentKey(token)
            let options = token.attributes["options"].map { list in
                list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } ?? []
            let argument = Argument(key: key, label: token.attributes["name"], defaultValue: token.attributes["default"],
                                    options: options)
            if let index = arguments.firstIndex(where: { $0.key == key }) {
                // A later mention can add what the first one left out.
                let first = arguments[index]
                arguments[index] = Argument(key: key, label: first.label ?? argument.label,
                                            defaultValue: first.defaultValue ?? argument.defaultValue,
                                            options: first.options.isEmpty ? argument.options : first.options)
            } else {
                arguments.append(argument)
            }
        }
        self.arguments = arguments
    }

    /// It asks for something before it opens.
    public var takesArgument: Bool { !arguments.isEmpty }

    /// Placeholders are percent-encoded by default: everywhere but in a file path.
    public var encodesByDefault: Bool { !Self.isPath(link) }

    /// The link with every placeholder replaced.
    public func filled(_ values: Values) -> String {
        var result = ""
        for piece in pieces {
            switch piece {
            case .text(let text):
                result += text
            case .token(let token):
                result += value(of: token, values)
            }
        }
        return result
    }

    private func value(of token: Token, _ values: Values) -> String {
        var text: String
        switch token.name {
        case "query", "argument":
            let key = Self.argumentKey(token)
            text = values.arguments[key] ?? ""
            if text.isEmpty, let fallback = arguments.first(where: { $0.key == key })?.defaultValue { text = fallback }
        case "clipboard":
            text = values.clipboard ?? ""
        case "uuid":
            text = values.makeUUID()
        default:
            text = Self.formatDate(token, values)
        }
        for modifier in token.modifiers {
            switch modifier {
            case "uppercase": text = text.uppercased()
            case "lowercase": text = text.lowercased()
            case "trim": text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "percent-encode": text = Self.percentEncode(text)
            case "json-stringify": text = Self.jsonString(text)
            default: break
            }
        }
        let encodesItself = token.modifiers.contains("raw") || token.modifiers.contains("percent-encode")
        if encodesByDefault, !encodesItself { text = Self.percentEncode(text) }
        return text
    }

    private static func argumentKey(_ token: Token) -> String {
        if token.name == "argument", let name = token.attributes["name"], !name.isEmpty { return name }
        return "query"
    }

    // MARK: Dates

    private static func formatDate(_ token: Token, _ values: Values) -> String {
        var date = values.date
        if let offset = token.attributes["offset"] {
            date = applying(offset: offset, to: date, calendar: values.calendar)
        }
        let formatter = DateFormatter()
        formatter.calendar = values.calendar
        formatter.timeZone = values.calendar.timeZone
        formatter.locale = token.attributes["locale"].map { Locale(identifier: $0) } ?? values.locale
        if let format = token.attributes["format"], !format.isEmpty {
            formatter.dateFormat = format
        } else {
            switch token.name {
            case "date":
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
            case "time":
                formatter.dateStyle = .none
                formatter.timeStyle = .short
            case "datetime":
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
            default:  // day
                formatter.setLocalizedDateFormatFromTemplate("EEEE")
            }
        }
        return formatter.string(from: date)
    }

    /// "+2y +5M -3d +3h +30m": years, months, weeks, days, hours, minutes; parts it can't read are skipped.
    static func applying(offset: String, to date: Date, calendar: Calendar) -> Date {
        var result = date
        for part in offset.split(whereSeparator: { $0 == " " || $0 == "," }) {
            var text = Substring(part)
            var sign = 1
            if text.first == "+" { text = text.dropFirst() } else if text.first == "-" { sign = -1; text = text.dropFirst() }
            guard let unit = text.last, let amount = Int(text.dropLast()) else { continue }
            let component: Calendar.Component
            switch unit {
            case "y": component = .year
            case "M": component = .month
            case "w": component = .weekOfYear
            case "d": component = .day
            case "h": component = .hour
            case "m": component = .minute
            default: continue
            }
            result = calendar.date(byAdding: component, value: sign * amount, to: result) ?? result
        }
        return result
    }

    // MARK: Encoding

    /// Everything but letters, digits and `-._~` as %XX of its UTF-8 bytes (RFC 3986's unreserved characters), so a
    /// value can go anywhere in a URL.
    public static func percentEncode(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
                 UInt8(ascii: "~"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// The text as a JSON string literal, quotes included.
    static func jsonString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    // MARK: Parsing

    /// The link cut into text and placeholders. A brace that doesn't open a known placeholder is text.
    static func parse(_ link: String) -> [Piece] {
        var pieces: [Piece] = []
        var text = ""
        var index = link.startIndex
        while index < link.endIndex {
            if link[index] == "{", let close = closingBrace(in: link, from: index),
               let token = token(String(link[link.index(after: index)..<close])) {
                if !text.isEmpty { pieces.append(.text(text)) }
                text = ""
                pieces.append(.token(token))
                index = link.index(after: close)
            } else {
                text.append(link[index])
                index = link.index(after: index)
            }
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    /// The `}` that closes the brace at `open`, skipping quoted attribute values; nil for none (or another `{` first).
    private static func closingBrace(in link: String, from open: String.Index) -> String.Index? {
        var quote: Character?
        var index = link.index(after: open)
        while index < link.endIndex {
            let character = link[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "}" {
                return index
            } else if character == "{" {
                return nil
            }
            index = link.index(after: index)
        }
        return nil
    }

    /// `name attr="value" | modifier | modifier` → a token, nil when it's not a placeholder this knows.
    static func token(_ inside: String) -> Token? {
        let parts = splitOutsideQuotes(inside, separator: "|")
        guard let head = parts.first else { return nil }
        var scanner = Substring(head).drop { $0 == " " }
        let name = String(scanner.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }).lowercased()
        guard tokenNames.contains(name) else { return nil }
        scanner = scanner.dropFirst(name.count)
        var attributes: [String: String] = [:]
        while true {
            scanner = scanner.drop { $0 == " " }
            guard !scanner.isEmpty else { break }
            let key = String(scanner.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            guard !key.isEmpty else { return nil }
            scanner = scanner.dropFirst(key.count).drop { $0 == " " }
            guard scanner.first == "=" else { return nil }
            scanner = scanner.dropFirst().drop { $0 == " " }
            let value: String
            if let quote = scanner.first, quote == "\"" || quote == "'" {
                let body = scanner.dropFirst()
                guard let end = body.firstIndex(of: quote) else { return nil }
                value = String(body[..<end])
                scanner = body[body.index(after: end)...]
            } else {
                let word = scanner.prefix { $0 != " " }
                value = String(word)
                scanner = scanner.dropFirst(word.count)
            }
            attributes[key.lowercased()] = value
        }
        let modifiers = parts.dropFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return Token(name: name, attributes: attributes, modifiers: modifiers)
    }

    private static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    // MARK: Where it goes

    /// A file or folder path ("/Users/me/Notes", "~/Downloads") rather than a URL.
    public static func isPath(_ link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    /// What a filled link opens: a path as a file URL (`~` is `home`), a URL as is, and a bare address
    /// ("github.com/apple") as https (http for localhost and IP addresses with a port). Nil when it's none of these.
    public static func destination(_ filled: String, home: String) -> URL? {
        let text = filled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("~") {
            let rest = text.dropFirst()
            guard rest.isEmpty || rest.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: home + rest)
        }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        if let colon = text.firstIndex(of: ":") {
            let scheme = text[..<colon]
            let afterColon = text[text.index(after: colon)...]
            let isScheme = scheme.first?.isLetter == true
                && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
            // "localhost:3000/x" is a host and a port, not a scheme.
            if isScheme, !(afterColon.first?.isNumber ?? false) { return url(text) }
            if afterColon.first?.isNumber == true, !text.contains(" ") {
                let host = scheme.lowercased()
                let local = host == "localhost" || host.allSatisfy { $0.isNumber || $0 == "." }
                return url((local ? "http://" : "https://") + text)
            }
            return nil
        }
        guard !text.contains(" "), text.contains("."), text.first != "." else { return nil }
        return url("https://" + text)
    }

    /// `URL(string:)`, with characters a URL can't hold (spaces in a `raw` value) encoded first.
    private static func url(_ text: String) -> URL? {
        if let url = URL(string: text) { return url }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: $0) }
    }

    /// What an argument's empty field says: "Search Google…" for Google Search's query, "To (en)…" for a named
    /// argument with a default.
    public static func prompt(for argument: Argument, quicklinkName name: String) -> String {
        if let label = argument.label, !label.isEmpty {
            var text = label.prefix(1).uppercased() + label.dropFirst()
            if let value = argument.defaultValue, !value.isEmpty { text += " (\(value))" }
            return text + "…"
        }
        let words = name.split(separator: " ").filter { $0.lowercased() != "search" }
        let subject = words.isEmpty ? name : words.joined(separator: " ")
        return "Search \(subject)…"
    }

    /// The link without "https://" and "www.", for a subtitle.
    public static func display(_ link: String) -> String {
        var text = link.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.lowercased().hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    /// The web host a link points at ("www.google.com"), for its favicon; nil for paths and app links.
    public static func webHost(_ link: String) -> String? {
        let sample = QuicklinkTemplate(link).filled(Values(arguments: [:], clipboard: "", makeUUID: { "" }))
        guard !isPath(link), let url = destination(sample, home: "/"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url.host?.lowercased()
    }
}

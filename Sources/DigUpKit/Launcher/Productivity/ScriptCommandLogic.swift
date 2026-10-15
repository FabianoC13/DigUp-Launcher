import Foundation

/// One argument a script command takes, from its `@raycast.argument1` … `argument3` JSON:
/// `{ "type": "text", "placeholder": "City", "optional": true, "percentEncoded": true }`.
public struct ScriptArgument: Equatable, Sendable {
    public enum Kind: String, Sendable { case text, password, dropdown }

    /// A dropdown's choice: shown as `title`, passed as `value`.
    public struct Option: Equatable, Sendable {
        public let title: String
        public let value: String

        public init(title: String, value: String) {
            self.title = title
            self.value = value
        }
    }

    public var kind: Kind
    public var placeholder: String
    public var optional: Bool
    public var percentEncoded: Bool
    public var options: [Option]

    public init(kind: Kind = .text, placeholder: String = "", optional: Bool = false, percentEncoded: Bool = false,
                options: [Option] = []) {
        self.kind = kind
        self.placeholder = placeholder
        self.optional = optional
        self.percentEncoded = percentEncoded
        self.options = options
    }

    /// Nil when it isn't a JSON object, or a dropdown without choices.
    public static func parse(json: String) -> ScriptArgument? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var argument = ScriptArgument()
        if let type = object["type"] as? String {
            guard let kind = Kind(rawValue: type) else { return nil }
            argument.kind = kind
        }
        argument.placeholder = object["placeholder"] as? String ?? ""
        argument.optional = flag(object["optional"])
        argument.percentEncoded = flag(object["percentEncoded"])
        if let data = object["data"] as? [[String: Any]] {
            argument.options = data.compactMap { entry in
                guard let value = entry["value"].map({ "\($0)" }) else { return nil }
                return Option(title: entry["title"] as? String ?? value, value: value)
            }
        }
        if argument.kind == .dropdown, argument.options.isEmpty { return nil }
        if argument.placeholder.isEmpty { argument.placeholder = argument.kind == .password ? "Password" : "Argument" }
        return argument
    }

    /// The value as the script gets it: percent-encoded when the argument asks (for a URL's query).
    public func encode(_ value: String) -> String {
        guard percentEncoded else { return value }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func flag(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let text = value as? String { return text.lowercased() == "true" }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}

/// A script command's `@raycast.*` comments, the metadata Raycast's Script Commands use:
///
///     #!/bin/bash
///     # @raycast.schemaVersion 1
///     # @raycast.title Weather
///     # @raycast.mode compact
///     # @raycast.argument1 { "type": "text", "placeholder": "City" }
///
/// Comments start with `#`, `//` or `--`, so any language works.
public struct ScriptCommandMetadata: Equatable, Sendable {
    /// What happens to the output: shown in full, its last line in a toast (compact) or a HUD (silent), or its last
    /// line kept in the list (inline).
    public enum Mode: String, Sendable { case fullOutput, compact, silent, inline }

    public var schemaVersion: Int?
    public var title: String
    public var mode: Mode
    public var packageName: String?
    public var icon: String?
    public var iconDark: String?
    public var description: String?
    public var arguments: [ScriptArgument]
    public var needsConfirmation: Bool
    public var currentDirectoryPath: String?
    /// How often an inline script runs again by itself ("10s", "5m", "1h", "1d" in the file).
    public var refreshTime: TimeInterval?
    public var author: String?
    public var authorURL: String?
    /// What was wrong but not fatal: an unknown mode (fullOutput is used), an argument that isn't valid JSON.
    public var warnings: [String]

    public init(title: String, mode: Mode = .fullOutput) {
        self.title = title
        self.mode = mode
        arguments = []
        needsConfirmation = false
        warnings = []
    }

    /// Only the first lines are read: the metadata is at the top.
    public static let headerLines = 200

    /// The metadata in a script's text; nil when it has no `@raycast.title` (it isn't a script command).
    public static func parse(_ text: String) -> ScriptCommandMetadata? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).prefix(headerLines) {
            guard let (key, value) = field(in: Substring(line)), values[key] == nil else { continue }
            values[key] = value
        }
        guard let title = values["title"], !title.isEmpty else { return nil }
        var metadata = ScriptCommandMetadata(title: title)
        if let mode = values["mode"] {
            if let known = Mode(rawValue: mode) {
                metadata.mode = known
            } else {
                metadata.warnings.append("Unknown mode “\(mode)”: showing the full output")
            }
        } else {
            metadata.warnings.append("No @raycast.mode: showing the full output")
        }
        metadata.schemaVersion = values["schemaVersion"].flatMap { Int($0) }
        metadata.packageName = values["packageName"]
        metadata.icon = values["icon"]
        metadata.iconDark = values["iconDark"]
        metadata.description = values["description"]
        metadata.needsConfirmation = values["needsConfirmation"]?.lowercased() == "true"
        metadata.currentDirectoryPath = values["currentDirectoryPath"]
        metadata.refreshTime = values["refreshTime"].flatMap(ScriptCommandLine.interval)
        metadata.author = values["author"]
        metadata.authorURL = values["authorURL"]
        for index in 1...3 {
            guard let json = values["argument\(index)"] else { break }
            if let argument = ScriptArgument.parse(json: json) {
                metadata.arguments.append(argument)
            } else {
                metadata.warnings.append("@raycast.argument\(index) isn't a valid argument")
                break
            }
        }
        return metadata
    }

    /// `# @raycast.title Weather` → ("title", "Weather"), for the comment markers `#`, `//` and `--`.
    static func field(in line: Substring) -> (String, String)? {
        var rest = line.drop { $0 == " " || $0 == "\t" }
        guard let marker = ["//", "--", "#"].first(where: { rest.hasPrefix($0) }) else { return nil }
        while rest.hasPrefix(marker) { rest = rest.dropFirst(marker.count) }
        rest = rest.drop { $0 == " " || $0 == "\t" }
        guard rest.hasPrefix("@raycast.") else { return nil }
        rest = rest.dropFirst("@raycast.".count)
        let key = rest.prefix { !$0.isWhitespace }
        let value = rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (String(key), value)
    }

    /// The arguments a run can't go without.
    public var requiredArguments: Int { arguments.filter { !$0.optional }.count }
}

/// Running a script command: what's typed after its title, its interpreter, its output.
public enum ScriptCommandLine {
    /// How well `query` names the script, and what's typed after the name: "weather berlin" for "Weather" → the
    /// score of "weather", and "berlin". Only a strong match of the leading words counts as the name (a prefix, word
    /// prefixes, initials), so arguments don't make the script vanish from the list. A script without arguments
    /// matches the whole query or not at all.
    public static func match(_ query: String, title: String, keywords: [String] = [], takesArguments: Bool = true)
        -> (score: Double, rest: String)? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let whole = FuzzyMatch.best(trimmed, name: title, keywords: keywords)
        if let whole, whole >= 0.7 || !takesArguments { return (whole, "") }
        guard takesArguments else { return nil }
        let words = wordRanges(trimmed)
        for count in stride(from: words.count - 1, through: 1, by: -1) {
            let head = String(trimmed[words[0].lowerBound..<words[count - 1].upperBound])
            guard let score = FuzzyMatch.best(head, name: title, keywords: keywords), score >= 0.7 else { continue }
            let rest = String(trimmed[words[count].lowerBound...]).trimmingCharacters(in: .whitespaces)
            return (score, rest)
        }
        return whole.map { ($0, "") }
    }

    private static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isWhitespace {
                if let begun = start { ranges.append(begun..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begun = start { ranges.append(begun..<text.endIndex) }
        return ranges
    }

    /// Typed arguments, one per word; "quoted words" stay together, and the last argument takes the rest of the line
    /// ("berlin germany" is one city for a script with one argument).
    public static func split(_ text: String, count: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard count > 0, !trimmed.isEmpty else { return [] }
        var values: [String] = []
        var rest = Substring(trimmed)
        while !rest.isEmpty, values.count < count - 1 {
            rest = rest.drop { $0 == " " }
            guard let first = rest.first else { break }
            if first == "\"" || first == "'", let close = rest.dropFirst().firstIndex(of: first) {
                values.append(String(rest[rest.index(after: rest.startIndex)..<close]))
                rest = rest[rest.index(after: close)...]
            } else {
                let word = rest.prefix { $0 != " " }
                values.append(String(word))
                rest = rest.dropFirst(word.count)
            }
        }
        var last = rest.trimmingCharacters(in: .whitespaces)
        if last.count >= 2, let first = last.first, first == "\"" || first == "'", last.last == first {
            last = String(last.dropFirst().dropLast())
        }
        if !last.isEmpty { values.append(last) }
        return values
    }

    /// The command for a script that isn't executable: its `#!` line ("#!/usr/bin/env python3" → ["/usr/bin/env",
    /// "python3"]), else its extension's usual interpreter. Nil when neither says.
    public static func interpreter(firstLine: String?, pathExtension: String) -> [String]? {
        if let line = firstLine?.trimmingCharacters(in: .whitespaces), line.hasPrefix("#!") {
            let parts = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if !parts.isEmpty { return parts }
        }
        switch pathExtension.lowercased() {
        case "sh", "bash", "command": return ["/bin/bash"]
        case "zsh": return ["/bin/zsh"]
        case "py": return ["/usr/bin/env", "python3"]
        case "rb": return ["/usr/bin/env", "ruby"]
        case "js", "mjs": return ["/usr/bin/env", "node"]
        case "ts": return ["/usr/bin/env", "npx", "ts-node"]
        case "swift": return ["/usr/bin/env", "swift"]
        case "php": return ["/usr/bin/env", "php"]
        case "pl": return ["/usr/bin/env", "perl"]
        case "applescript", "scpt": return ["/usr/bin/osascript"]
        default: return nil
        }
    }

    /// PATH for scripts: Homebrew's folders first (apps started from the Dock don't get the shell's PATH), then what
    /// was there, without repeats.
    public static func searchPath(existing: String?) -> String {
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let current = existing?.split(separator: ":").map(String.init) ?? []
        let base = current.isEmpty ? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] : current
        var seen = Set<String>()
        return (extra + base).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The last line with text, without terminal colors: what compact, silent and inline scripts show.
    public static func lastLine(_ output: String) -> String? {
        stripANSI(output).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// Without terminal escape sequences (colors, bold, cursor moves).
    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = ""
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        while let scalar = pending ?? iterator.next() {
            pending = nil
            guard scalar == "\u{1B}" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            guard let next = iterator.next() else { break }
            if next == "[" {
                // CSI: parameters and intermediates, then one final byte from @ to ~.
                while let byte = iterator.next() {
                    if (0x40...0x7E).contains(byte.value) { break }
                }
            } else if next == "]" {
                // OSC: up to BEL or ESC \.
                while let byte = iterator.next() {
                    if byte == "\u{07}" { break }
                    if byte == "\u{1B}" { _ = iterator.next(); break }
                }
            } else if !(0x40...0x5F).contains(next.value) {
                pending = next
            }
        }
        return result
    }

    /// "10s", "5m", "1h", "1d" → seconds; nil for anything else.
    public static func interval(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = trimmed.last, let value = Double(trimmed.dropLast()), value > 0 else { return nil }
        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86_400
        default: return nil
        }
    }

    /// A file name for a new script: "Say Hello!" → "say-hello.sh".
    public static func fileName(forTitle title: String, extension ext: String = "sh") -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var slug = ""
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return (slug.isEmpty ? "script-command" : slug) + "." + ext
    }

    /// A new Bash script command with its metadata filled in, ready to edit.
    public static func template(title: String, packageName: String? = nil) -> String {
        let cleanTitle = title.replacingOccurrences(of: "\n", with: " ")
        return """
            #!/bin/bash

            # Required parameters:
            # @raycast.schemaVersion 1
            # @raycast.title \(cleanTitle)
            # @raycast.mode compact

            # Optional parameters:
            # @raycast.packageName \(packageName ?? "Script Commands")
            # @raycast.argument1 { "type": "text", "placeholder": "Name", "optional": true }
            # @raycast.needsConfirmation false

            # Documentation:
            # @raycast.description \(cleanTitle)

            # Modes: fullOutput shows everything printed, compact and inline the last line, silent a short HUD.
            # Arguments arrive as $1, $2 and $3.

            echo "Hello, ${1:-World}!"

            """
    }
}

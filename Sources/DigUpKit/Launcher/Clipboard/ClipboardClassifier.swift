import Foundation

/// What a copied text is (a link, an email address, a color, plain text), whether it reads as code, and its title.
public enum ClipboardClassifier {
    /// The longest title a row shows.
    public static let titleLength = 80

    /// A link when the whole text is one web address, an email when it's one address, a color when it's a CSS color
    /// ("#FF8800", "rgb(255 136 0)"), else text.
    public static func kind(of text: String) -> ClipboardEntry.Kind {
        if ClipboardColor(parsing: text) != nil { return .color }
        if link(in: text) != nil { return .link }
        if email(in: text) != nil { return .email }
        return .text
    }

    /// The web address the whole text is ("https://apple.com/mac", "www.apple.com"), or nil.
    public static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 4096, !trimmed.contains(where: \.isWhitespace) else { return nil }
        var candidate = trimmed
        if candidate.lowercased().hasPrefix("www.") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp"].contains(scheme),
              let host = url.host, !host.isEmpty,
              host.contains(".") || host.contains(":") || host.lowercased() == "localhost" else { return nil }
        return url
    }

    /// The email address the whole text is ("ana@example.com", "mailto:ana@example.com"), or nil.
    public static func email(in text: String) -> String? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, address.utf8.count <= 254 else { return nil }
        let local = parts[0], domain = parts[1]
        let localAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".!#$%&'*+/=?^_`{|}~-"))
        guard !local.isEmpty, local.unicodeScalars.allSatisfy(localAllowed.contains),
              !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..") else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let labelAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(labelAllowed.contains) }),
              let top = labels.last, top.count >= 2, top.allSatisfy(\.isLetter) else { return nil }
        return address
    }

    /// Whether the text reads as code (JSON, a function, a shell script), so it's previewed in a monospaced font.
    /// Only the first 2,000 characters are looked at.
    public static func looksLikeCode(_ text: String) -> Bool {
        let sample = String(text.prefix(2000))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        // JSON, arrays, markup.
        if let first = trimmed.first, let last = trimmed.last,
           (first == "{" && last == "}") || (first == "[" && last == "]") || (first == "<" && last == ">") {
            return true
        }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        var score = 0
        let starts = ["func ", "let ", "var ", "const ", "def ", "class ", "struct ", "enum ", "import ", "#include",
                      "#import", "return ", "if (", "for (", "while (", "public ", "private ", "fn ", "impl ", "package ",
                      "#!/", "SELECT ", "select ", "INSERT ", "UPDATE ", "CREATE ", "export ", "function ", "async ",
                      "from ", "using ", "namespace ", "@", "}", "};", "end", "<?php", "$ ", "sudo ", "npm ", "git ",
                      "cd ", "echo ", "brew ", "swift "]
        let startingLikeCode = lines.filter { line in
            let stripped = line.drop { $0 == " " || $0 == "\t" }
            return starts.contains { stripped.hasPrefix($0) }
        }.count
        if startingLikeCode >= 1 { score += 1 }
        if startingLikeCode >= 2 || (lines.count == 1 && startingLikeCode == 1 && trimmed.contains { "(){};=|".contains($0) }) {
            score += 1
        }
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") || $0.hasPrefix("  ") }.count
        if lines.count >= 3, indented >= 2 { score += 1 }
        let endsLikeCode = lines.filter { line in
            let end = line.trimmingCharacters(in: .whitespaces)
            return end.hasSuffix(";") || end.hasSuffix("{") || end.hasSuffix("}") || end.hasSuffix(")")
                || end.hasSuffix(",") && end.hasPrefix("\"")
        }.count
        if endsLikeCode >= max(1, lines.count / 3) { score += 1 }
        let symbols = trimmed.filter { "{}[]();=<>_$|\\".contains($0) }.count
        let letters = max(1, trimmed.filter(\.isLetter).count)
        if Double(symbols) / Double(letters) > 0.12 { score += 1 }
        for token in ["=>", "->", "::", "!=", "==", "&&", "||", "</", "/>", "+=", ":="] where trimmed.contains(token) {
            score += 1
            break
        }
        return score >= 2
    }

    /// The first non-empty line, trimmed, 80 characters at most.
    public static func title(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return clipped(line)
    }

    /// `text`, cut to `titleLength` characters with "…".
    public static func clipped(_ text: String) -> String {
        guard text.count > titleLength else { return text }
        return String(text.prefix(titleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Words, as a word processor counts them (runs of letters and digits).
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text {
            let isWordCharacter = character.isLetter || character.isNumber || character == "'" || character == "’"
            if isWordCharacter, !inWord { count += 1 }
            inWord = isWordCharacter
        }
        return count
    }

    /// Lines in the text (1 for a single line).
    public static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(whereSeparator: \.isNewline).count
    }
}

/// A color written the CSS way: "#F80", "#FF8800", "#FF880080", "rgb(255, 136, 0)", "rgba(255 136 0 / 50%)",
/// "hsl(32, 100%, 50%)". Components run from 0 to 1.
public struct ClipboardColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The color the whole text spells, or nil.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        if trimmed.hasPrefix("#") {
            guard let color = Self.hex(String(trimmed.dropFirst())) else { return nil }
            self = color
            return
        }
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return nil }
        let function = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        let parts = inner.split { $0 == "," || $0 == " " || $0 == "/" }.map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        let alpha: Double
        if parts.count == 4 {
            guard let value = Self.number(parts[3], percentScale: 1), (0...1).contains(value) else { return nil }
            alpha = value
        } else {
            alpha = 1
        }
        switch function {
        case "rgb", "rgba":
            let channels = parts.prefix(3).map { Self.number($0, percentScale: 255) }
            guard channels.allSatisfy({ $0 != nil && (0...255).contains($0!) }) else { return nil }
            self.init(red: channels[0]! / 255, green: channels[1]! / 255, blue: channels[2]! / 255, alpha: alpha)
        case "hsl", "hsla":
            let hueText = parts[0].hasSuffix("deg") ? String(parts[0].dropLast(3)) : parts[0]
            guard let hue = Double(hueText),
                  let saturation = Self.number(parts[1], percentScale: 1, bareIsPercent: true),
                  let lightness = Self.number(parts[2], percentScale: 1, bareIsPercent: true),
                  (0...1).contains(saturation), (0...1).contains(lightness) else { return nil }
            self = Self.fromHSL(hue: hue, saturation: saturation, lightness: lightness, alpha: alpha)
        default:
            return nil
        }
    }

    /// "#FF8800", with the alpha ("#FF880080") when it isn't opaque.
    public var hex: String {
        let channels = [red, green, blue] + (alpha < 1 ? [alpha] : [])
        return "#" + channels.map { String(format: "%02X", Self.byte($0)) }.joined()
    }

    /// "rgb(255, 136, 0)", or "rgba(255, 136, 0, 0.5)".
    public var rgb: String {
        let channels = "\(Self.byte(red)), \(Self.byte(green)), \(Self.byte(blue))"
        return alpha < 1 ? "rgba(\(channels), \(Self.decimal(alpha)))" : "rgb(\(channels))"
    }

    /// "hsl(32, 100%, 50%)", or "hsla(…, 0.5)".
    public var hsl: String {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        var hue = 0.0, saturation = 0.0
        let delta = maximum - minimum
        if delta > 0 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            switch maximum {
            case red: hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            case green: hue = 60 * ((blue - red) / delta + 2)
            default: hue = 60 * ((red - green) / delta + 4)
            }
            if hue < 0 { hue += 360 }
        }
        let body = "\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%"
        return alpha < 1 ? "hsla(\(body), \(Self.decimal(alpha)))" : "hsl(\(body))"
    }

    private static func hex(_ digits: String) -> ClipboardColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
        var values: [Double] = []
        var index = expanded.startIndex
        while index < expanded.endIndex {
            let next = expanded.index(index, offsetBy: 2)
            values.append(Double(UInt8(expanded[index..<next], radix: 16)!) / 255)
            index = next
        }
        return ClipboardColor(red: values[0], green: values[1], blue: values[2], alpha: values.count == 4 ? values[3] : 1)
    }

    /// "50%" → 0.5 × `percentScale`, "0.5" → 0.5 (or 0.5% of the scale with `bareIsPercent`).
    private static func number(_ text: String, percentScale: Double, bareIsPercent: Bool = false) -> Double? {
        if text.hasSuffix("%") {
            guard let value = Double(text.dropLast()) else { return nil }
            return value / 100 * percentScale
        }
        guard let value = Double(text) else { return nil }
        return bareIsPercent ? value / 100 * percentScale : value
    }

    private static func fromHSL(hue: Double, saturation: Double, lightness: Double, alpha: Double) -> ClipboardColor {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<1: (r, g, b) = (chroma, x, 0)
        case ..<2: (r, g, b) = (x, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, x)
        case ..<4: (r, g, b) = (0, x, chroma)
        case ..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let m = lightness - chroma / 2
        return ClipboardColor(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    private static func byte(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    private static func decimal(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

import Foundation

/// The calculator's front door: one typed question in, at most one answer out. Each kind of question is tried in turn
/// (colors, time zones, dates, number bases, units and currency, then plain math); each parser gives up quickly on
/// what isn't its own, so this stays fast enough to run on every keystroke. Plain words ("safari"), a lone number
/// ("42") or a lone date ("dec 25") get no answer.
public enum CalcEngine {
    public static func answer(_ input: String, env: CalcEnvironment) -> CalcAnswer? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300, worthTrying(text) else { return nil }
        if env.colorsEnabled, let found = color(text) { return found }
        if let found = CalcTimeZones.answer(text, env: env) { return found }
        if let found = CalcDates.answer(text, env: env) { return found }
        if let found = CalcBases.answer(text, env: env) { return found }
        if let found = CalcConversion.answer(text, env: env) { return found }
        return math(text, env: env)
    }

    /// A cheap first look: questions have a digit, an operator or symbol, or one of a few key words.
    static func worthTrying(_ text: String) -> Bool {
        if text.contains(where: { $0.isNumber || "+-*/^%!()#√π×÷=²³°$€£¥₹₩₽₺₪฿".contains($0) }) { return true }
        let lower = text.lowercased()
        let words = ["time", "now", "noon", "midnight", "day", "week", "month", "year", "until", "till", "since",
                     "unix", "epoch", "timestamp", "diff", "pi", "tau", "phi", "sqrt", "root", "roman", "christmas",
                     "xmas", "easter", "halloween", "thanksgiving", "valentine", "workhours", "work hours", "hex",
                     "binary", "ago", "tomorrow", "yesterday", "today", "monday", "tuesday", "wednesday", "thursday",
                     "friday", "saturday", "sunday", "in ", "to ", "new year", "end of"]
        return words.contains { lower.contains($0) }
    }

    /// "#ff8800", "rgb(255 136 0)", "hsl(32, 100%, 50%)", "oklch(0.73 0.18 56)".
    static func color(_ text: String) -> CalcAnswer? {
        guard text.hasPrefix("#") || text.contains("("), let color = CalcColor.parse(text) else { return nil }
        let formats = color.formats
        let result = color.alpha < 1 ? color.hexAlpha : color.hex
        let rgb = formats.first { $0.label == "RGBA" }?.value ?? ""
        let hsl = formats.first { $0.label == "HSLA" }?.value ?? ""
        return CalcAnswer(kind: .color, result: result, expression: text, caption: "\(rgb) · \(hsl)",
                          alternatives: formats, color: color)
    }

    static func math(_ input: String, env: CalcEnvironment) -> CalcAnswer? {
        // "what is 2+2", "calculate 3*4".
        var text = input
        let lower = CalcText.clean(input)
        for prefix in ["what is", "what's", "whats", "calculate", "calc", "compute", "solve"] {
            if CalcText.dropPrefix(prefix, from: lower) != nil {
                text = String(CalcText.clean(input, lowercased: false).dropFirst(prefix.count + 1))
                break
            }
        }
        text = text.replacingOccurrences(of: "?", with: "")
        guard !looksLikeDate(text), let result = CalcExpression.evaluate(text, env: env), !result.isTrivial
        else { return nil }
        let format = env.format
        let shown = format.number(result.value) + (result.isPercent ? "%" : "")
        var expression = CalcText.clean(text, lowercased: false)
        while expression.hasSuffix("=") || expression.hasSuffix(" ") { expression.removeLast() }
        var alternatives: [CalcAlternative] = []
        let written = expression.lowercased()
        if written.contains("0x") || written.contains("0b") || written.contains("0o"),
           result.value == result.value.rounded(), abs(result.value) < 9.2e18 {
            let value = Int(result.value)
            alternatives = [CalcAlternative("Hex", CalcBases.write(value, base: 16, format: format)),
                            CalcAlternative("Binary", CalcBases.write(value, base: 2, format: format))]
        }
        return CalcAnswer(kind: .math, result: shown, expression: expression, caption: "\(expression) = \(shown)",
                          number: format.raw(result.value), alternatives: alternatives)
    }
}

extension CalcEngine {
    /// "2027-03-14", "3/14/2027", "14.03.2027": a date, not a subtraction or a division.
    static func looksLikeDate(_ text: String) -> Bool {
        for separator: Character in ["-", "/", "."] {
            let parts = text.split(separator: separator, omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCIIDigit) })
            else { continue }
            if parts[0].count == 4 || parts[2].count == 4 { return true }
        }
        return false
    }
}

/// "define serendipity", "def X", "X meaning", "meaning of X", "definition of X", "what does X mean".
public enum CalcDefine {
    /// The word or phrase to look up, nil when the question isn't a definition request.
    public static func term(in input: String) -> String? {
        let text = CalcText.clean(input).replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(in: .whitespaces)
        var found: String?
        if let rest = CalcText.dropPrefix("what does", from: text) {
            found = CalcText.dropSuffix("mean", from: rest)
        } else if let rest = CalcText.dropAnyPrefix(["what is the meaning of", "what's the meaning of", "the meaning of",
                                                     "meaning of", "definition of", "define", "def", "dict",
                                                     "dictionary"], from: text) {
            found = rest
        } else {
            found = CalcText.dropSuffix("meaning", from: text) ?? CalcText.dropSuffix("definition", from: text)
        }
        guard let term = found?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")), !term.isEmpty,
              term.count <= 60, term.split(separator: " ").count <= 4, term.contains(where: \.isLetter)
        else { return nil }
        return term
    }
}

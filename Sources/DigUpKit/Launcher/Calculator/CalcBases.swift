import Foundation

/// Number bases and Roman numerals: "0xff", "255 in hex", "0b1010 in dec", "255 to binary", "0o17", "hex ff",
/// "ff hex", "255 in base 36", "2024 in roman", "MMXXIV in decimal", "roman xiv".
public enum CalcBases {
    static let names: [String: Int] = [
        "hex": 16, "hexadecimal": 16, "base16": 16, "base 16": 16,
        "bin": 2, "binary": 2, "base2": 2, "base 2": 2,
        "oct": 8, "octal": 8, "base8": 8, "base 8": 8,
        "dec": 10, "decimal": 10, "base10": 10, "base 10": 10, "arabic": 10, "number": 10, "int": 10, "integer": 10,
    ]

    static let prefixNames: [(String, Int)] = [("hexadecimal", 16), ("hex", 16), ("binary", 2), ("bin", 2), ("octal", 8)]

    public static func answer(_ input: String, env: CalcEnvironment) -> CalcAnswer? {
        let text = CalcText.clean(input)
        guard !text.isEmpty, text.count <= 100 else { return nil }
        // A lone literal: "0xff", "0b1010", "0o17".
        if let value = literal(text) {
            return answer(value, base: 10, expression: text, env: env)
        }
        // "hex ff", "binary 1010", "roman xiv" ("oct 17" is a date, so octal needs its full name here).
        for (name, base) in prefixNames {
            if let rest = CalcText.dropPrefix(name, from: text) ?? CalcText.dropSuffix(name, from: text),
               !rest.isEmpty, let value = digits(rest, base: base) {
                return answer(value, base: 10, expression: "\(rest) (\(name))", env: env)
            }
        }
        if let rest = CalcText.dropPrefix("roman numeral", from: text) ?? CalcText.dropPrefix("roman", from: text) {
            if let value = romanValue(rest) {
                return answer(value, base: 10, expression: rest.uppercased(), env: env)
            }
            if let value = Int(rest), let roman = roman(value) {
                return romanAnswer(roman, value: value, expression: rest, env: env)
            }
        }
        return CalcText.splitLast(text, separators: ["in", "to", "as", "into"]) { left, right in
            convert(left, to: right, env: env)
        }
    }

    static func convert(_ left: String, to right: String, env: CalcEnvironment) -> CalcAnswer? {
        let target: Int?
        if ["roman", "roman numerals", "roman numeral", "numerals"].contains(right) {
            target = nil
        } else if let base = names[right] {
            target = base
        } else if let rest = CalcText.dropPrefix("base", from: right), let base = Int(rest), (2...36).contains(base) {
            target = base
        } else {
            return nil
        }
        // The source: a Roman numeral, digits with a base name ("ff hex"), or any integer expression.
        var value: Int?
        if target == 10 || target == nil, let roman = romanValue(left), Double(left) == nil { value = roman }
        if value == nil {
            for (name, base) in prefixNames {
                if let rest = CalcText.dropSuffix(name, from: left) ?? CalcText.dropPrefix(name, from: left),
                   let found = digits(rest, base: base) {
                    value = found
                    break
                }
            }
        }
        if value == nil, let result = CalcExpression.evaluate(left, env: env), !result.isPercent,
           result.value == result.value.rounded(), abs(result.value) < 9.2e18 {
            // "42 in decimal" asks nothing.
            if target == 10, result.isTrivial { return nil }
            value = Int(result.value)
        }
        guard let value else { return nil }
        guard let target else {
            guard let roman = roman(value) else { return nil }
            return romanAnswer(roman, value: value, expression: left, env: env)
        }
        return answer(value, base: target, expression: "\(left) → \(baseName(target))", env: env)
    }

    /// `value` written in `base`, with every other common base alongside.
    static func answer(_ value: Int, base: Int, expression: String, env: CalcEnvironment) -> CalcAnswer {
        let result = write(value, base: base, format: env.format)
        let alternatives = [16, 2, 8, 10].filter { $0 != base }.map {
            CalcAlternative(baseName($0).capitalized, write(value, base: $0, format: env.format))
        }
        let caption = ([result] + alternatives.map(\.value)).joined(separator: " = ")
        return CalcAnswer(kind: .base, result: result, expression: expression, caption: caption,
                          number: String(value), alternatives: alternatives)
    }

    static func romanAnswer(_ roman: String, value: Int, expression: String, env: CalcEnvironment) -> CalcAnswer {
        CalcAnswer(kind: .base, result: roman, expression: "\(expression) → Roman numerals",
                   caption: "\(env.format.integer(value)) = \(roman)", number: String(value))
    }

    static func baseName(_ base: Int) -> String {
        switch base {
        case 16: "hex"
        case 2: "binary"
        case 8: "octal"
        case 10: "decimal"
        default: "base \(base)"
        }
    }

    /// "0xFF", "0b1010", "0o17", "255" (grouped), or plain digits in other bases.
    static func write(_ value: Int, base: Int, format: CalcFormat) -> String {
        if base == 10 { return format.integer(value) }
        let sign = value < 0 ? "-" : ""
        let digits = String(value.magnitude, radix: base, uppercase: true)
        switch base {
        case 16: return "\(sign)0x\(digits)"
        case 2: return "\(sign)0b\(digits)"
        case 8: return "\(sign)0o\(digits)"
        default: return sign + digits
        }
    }

    /// The value of "0xff", "0b1010" or "0o17", nil for anything else.
    static func literal(_ text: String) -> Int? {
        guard text.count > 2, text.hasPrefix("0") || text.hasPrefix("-0") else { return nil }
        let negative = text.hasPrefix("-")
        let body = negative ? String(text.dropFirst()) : text
        let base: Int
        switch body.dropFirst().first {
        case "x": base = 16
        case "b": base = 2
        case "o": base = 8
        default: return nil
        }
        guard let value = digits(String(body.dropFirst(2)), base: base) else { return nil }
        return negative ? -value : value
    }

    /// Digits in `base` ("ff", "1010", "0xff" for hex, underscores allowed), nil if any doesn't belong.
    static func digits(_ text: String, base: Int) -> Int? {
        var body = text.replacingOccurrences(of: "_", with: "")
        let prefix = base == 16 ? "0x" : (base == 2 ? "0b" : (base == 8 ? "0o" : ""))
        if !prefix.isEmpty, body.hasPrefix(prefix) { body.removeFirst(2) }
        guard !body.isEmpty, body.count <= 64 else { return nil }
        return Int(body, radix: base)
    }

    // MARK: Roman numerals

    private static let romanTable: [(Int, String)] = [
        (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
        (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]

    /// 1…3999 in Roman numerals.
    public static func roman(_ value: Int) -> String? {
        guard (1...3999).contains(value) else { return nil }
        var rest = value
        var text = ""
        for (amount, symbol) in romanTable {
            while rest >= amount {
                text += symbol
                rest -= amount
            }
        }
        return text
    }

    /// The value of a well-formed Roman numeral ("MMXXIV", "xiv"), nil otherwise.
    public static func romanValue(_ text: String) -> Int? {
        let upper = text.uppercased()
        guard !upper.isEmpty, upper.count <= 15, upper.allSatisfy({ "MDCLXVI".contains($0) }) else { return nil }
        let values: [Character: Int] = ["M": 1000, "D": 500, "C": 100, "L": 50, "X": 10, "V": 5, "I": 1]
        var total = 0
        let chars = Array(upper)
        for (index, c) in chars.enumerated() {
            let value = values[c] ?? 0
            if index + 1 < chars.count, value < (values[chars[index + 1]] ?? 0) {
                total -= value
            } else {
                total += value
            }
        }
        // Only the canonical spelling counts ("IIII" and "VX" aren't numerals).
        return roman(total) == upper ? total : nil
    }
}

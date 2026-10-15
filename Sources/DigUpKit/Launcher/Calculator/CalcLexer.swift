import Foundation

/// One piece of a math expression.
struct CalcToken: Equatable {
    enum Kind: Equatable {
        case number(Double)
        /// A lowercased word: a function, a constant, or an operator spelled out ("of", "mod", "x").
        case word(String)
        /// One of + - * / ^ % ! ( ) , ;
        case symbol(Character)
    }

    var kind: Kind
    /// Whether whitespace came before it ("10 % 3" is a remainder, "50 + 10%" a percentage).
    var spaceBefore = false
    /// How the number was written, when that matters: in another base ("0xff") or with a shorthand ("10k").
    var notation: Notation = .plain

    enum Notation: Equatable { case plain, base, shorthand }

    static func symbol(_ c: Character) -> CalcToken { CalcToken(kind: .symbol(c)) }
    static func word(_ w: String) -> CalcToken { CalcToken(kind: .word(w)) }
    static func number(_ x: Double) -> CalcToken { CalcToken(kind: .number(x)) }

    var word: String? { if case .word(let w) = kind { w } else { nil } }
    var symbol: Character? { if case .symbol(let c) = kind { c } else { nil } }
    var number: Double? { if case .number(let x) = kind { x } else { nil } }
}

/// Splits an expression into tokens: numbers in the locale's notation (1,234.5 or 1.234,5), 1e3, 0xff/0b101/0o17,
/// 10k and 2M, words, and operators including × ÷ − √ ² ³ °, then turns spelled-out operators into symbols
/// ("divided by" → /, "to the power of" → ^, "squared" → ^2).
enum CalcLexer {
    /// The tokens of `text` (case kept, so "2M" is two million and "2m" isn't a number), nil when a character can't
    /// be part of an expression.
    static func tokens(_ text: String, format: CalcFormat) -> [CalcToken]? {
        let chars = Array(text)
        let decimalComma = format.decimalSeparator == ","
        var out: [CalcToken] = []
        var i = 0
        var space = false
        while i < chars.count {
            let c = chars[i]
            if c == " " {
                space = true
                i += 1
                continue
            }
            defer { space = false }
            if c.isASCII, c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isASCIIDigit) {
                guard let (value, notation, next) = scanNumber(chars, from: i, decimalComma: decimalComma) else {
                    return nil
                }
                out.append(CalcToken(kind: .number(value), spaceBefore: space, notation: notation))
                i = next
                continue
            }
            if c.isASCII, c.isLetter {
                var j = i
                while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j] == "_" { j += 1 }
                var word = String(chars[i..<j]).lowercased()
                if word == "log" {
                    for base in ["10", "2"] where j + base.count <= chars.count
                        && String(chars[j..<(j + base.count)]) == base
                        && (j + base.count == chars.count || !chars[j + base.count].isASCIIDigit) {
                        word += base
                        j += base.count
                        break
                    }
                }
                out.append(CalcToken(kind: .word(word), spaceBefore: space))
                i = j
                continue
            }
            switch c {
            case "+", "-", "/", "^", "%", "!", "(", ")", ",", ";":
                out.append(CalcToken(kind: .symbol(c), spaceBefore: space))
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    out.append(CalcToken(kind: .symbol("^"), spaceBefore: space))
                    i += 1
                } else {
                    out.append(CalcToken(kind: .symbol("*"), spaceBefore: space))
                }
            case "×", "·", "⋅", "∙": out.append(CalcToken(kind: .symbol("*"), spaceBefore: space))
            case "÷", "∕": out.append(CalcToken(kind: .symbol("/"), spaceBefore: space))
            case "[", "{": out.append(CalcToken(kind: .symbol("("), spaceBefore: space))
            case "]", "}": out.append(CalcToken(kind: .symbol(")"), spaceBefore: space))
            case "√": out.append(CalcToken(kind: .word("sqrt"), spaceBefore: space))
            case "∛": out.append(CalcToken(kind: .word("cbrt"), spaceBefore: space))
            case "π", "Π": out.append(CalcToken(kind: .word("pi"), spaceBefore: space))
            case "τ": out.append(CalcToken(kind: .word("tau"), spaceBefore: space))
            case "φ", "ϕ": out.append(CalcToken(kind: .word("phi"), spaceBefore: space))
            case "°": out.append(CalcToken(kind: .word("deg"), spaceBefore: space))
            case "²", "³":
                out.append(.symbol("^"))
                out.append(.number(c == "²" ? 2 : 3))
            case "=":
                // "2+2=" asks for the answer; an "=" anywhere else isn't math.
                guard chars[(i + 1)...].allSatisfy({ $0 == " " || $0 == "=" }) else { return nil }
                i = chars.count
                continue
            default:
                return nil
            }
            i += 1
        }
        return phrases(out)
    }

    /// Reads one number starting at `start`: the value, how it was written, and where it ends.
    static func scanNumber(_ c: [Character], from start: Int,
                           decimalComma: Bool) -> (Double, CalcToken.Notation, Int)? {
        var i = start
        // 0x / 0b / 0o literals.
        if c[i] == "0", i + 2 < c.count {
            let radix: Int? = switch c[i + 1] {
            case "x", "X": 16
            case "b", "B": 2
            case "o", "O": 8
            default: nil
            }
            if let radix, Int(String(c[i + 2]), radix: radix) != nil {
                var j = i + 2
                var digits = ""
                while j < c.count, c[j].isHexDigit || c[j] == "_" {
                    if c[j] != "_" { digits.append(c[j]) }
                    j += 1
                }
                if j < c.count, c[j].isLetter { return nil }
                guard let value = UInt64(digits, radix: radix) else { return nil }
                return (Double(value), .base, j)
            }
        }
        let groupMark: Character = decimalComma ? "." : ","
        let decimalMark: Character = decimalComma ? "," : "."
        var text = ""
        var firstRun = 0
        while i < c.count, c[i].isASCIIDigit {
            text.append(c[i])
            i += 1
            firstRun += 1
        }
        // Thousands groups: exactly three digits after each mark, and the first run at most three long.
        if firstRun >= 1, firstRun <= 3 {
            while i < c.count, c[i] == groupMark, isGroup(c, at: i + 1) {
                text += String(c[(i + 1)...(i + 3)])
                i += 4
            }
        }
        if i + 1 < c.count, c[i] == decimalMark || (decimalComma && c[i] == "."), c[i + 1].isASCIIDigit {
            text.append(".")
            i += 1
            while i < c.count, c[i].isASCIIDigit {
                text.append(c[i])
                i += 1
            }
        } else if i < c.count, c[i] == ".", text.isEmpty {
            return nil
        }
        if text.isEmpty { return nil }
        // Exponent: 1e3, 2.5E-4 (but "2e" alone is 2 times e).
        if i + 1 < c.count, c[i] == "e" || c[i] == "E" {
            var j = i + 1
            if c[j] == "+" || c[j] == "-" { j += 1 }
            if j < c.count, c[j].isASCIIDigit {
                var exponent = String(c[(i + 1)..<j])
                while j < c.count, c[j].isASCIIDigit {
                    exponent.append(c[j])
                    j += 1
                }
                if j >= c.count || !c[j].isLetter {
                    text += "e" + exponent
                    i = j
                }
            }
        }
        guard var value = Double(text) else { return nil }
        var notation = CalcToken.Notation.plain
        // Shorthand: 10k, 2.5M (capital M: a lowercase m is meters).
        if i < c.count, c[i] == "k" || c[i] == "K" || c[i] == "M", i + 1 >= c.count || !c[i + 1].isLetter {
            value *= c[i] == "M" ? 1e6 : 1e3
            notation = .shorthand
            i += 1
        }
        return (value, notation, i)
    }

    private static func isGroup(_ c: [Character], at i: Int) -> Bool {
        guard i + 2 < c.count, c[i].isASCIIDigit, c[i + 1].isASCIIDigit, c[i + 2].isASCIIDigit else { return false }
        return i + 3 >= c.count || !c[i + 3].isASCIIDigit
    }

    /// Spelled-out operators, longest phrase first.
    private static let phraseTable: [([String], [CalcToken])] = [
        (["raised", "to", "the", "power", "of"], [.symbol("^")]),
        (["to", "the", "power", "of"], [.symbol("^")]),
        (["to", "the", "power"], [.symbol("^")]),
        (["raised", "to"], [.symbol("^")]),
        (["power", "of"], [.symbol("^")]),
        (["power"], [.symbol("^")]),
        (["divided", "by"], [.symbol("/")]),
        (["multiplied", "by"], [.symbol("*")]),
        (["times"], [.symbol("*")]),
        (["plus"], [.symbol("+")]),
        (["minus"], [.symbol("-")]),
        (["over"], [.symbol("/")]),
        (["squared"], [.symbol("^"), .number(2)]),
        (["cubed"], [.symbol("^"), .number(3)]),
        (["square", "root", "of"], [.word("sqrt")]),
        (["square", "root"], [.word("sqrt")]),
        (["cube", "root", "of"], [.word("cbrt")]),
        (["cube", "root"], [.word("cbrt")]),
        (["sqrt", "of"], [.word("sqrt")]),
        (["cbrt", "of"], [.word("cbrt")]),
        (["factorial", "of"], [.word("fact")]),
        (["factorial"], [.symbol("!")]),
        (["percentage"], [.symbol("%")]),
        (["percent"], [.symbol("%")]),
        (["pct"], [.symbol("%")]),
        (["modulo"], [.word("mod")]),
        (["degrees"], [.word("deg")]),
        (["degree"], [.word("deg")]),
        (["radians"], [.word("rad")]),
        (["radian"], [.word("rad")]),
    ]

    static func phrases(_ tokens: [CalcToken]) -> [CalcToken] {
        guard tokens.contains(where: { $0.word != nil }) else { return tokens }
        var out: [CalcToken] = []
        var i = 0
        outer: while i < tokens.count {
            if tokens[i].word != nil {
                for (words, replacement) in phraseTable where i + words.count <= tokens.count {
                    if (0..<words.count).allSatisfy({ tokens[i + $0].word == words[$0] }) {
                        for (n, var token) in replacement.enumerated() {
                            token.spaceBefore = n == 0 ? tokens[i].spaceBefore : false
                            out.append(token)
                        }
                        i += words.count
                        continue outer
                    }
                }
            }
            out.append(tokens[i])
            i += 1
        }
        return out
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

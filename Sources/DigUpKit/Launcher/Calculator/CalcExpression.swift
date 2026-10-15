import Foundation

/// A number while an expression is worked out, with what the calculator knows about it.
struct CalcValue {
    var number: Double
    /// Written as a percentage ("20%"): `number` is already the fraction (0.2).
    var isPercent = false
    /// An explicit angle unit ("30°", "1 rad").
    var angle: CalcAngleMode?
    /// Whether π or τ went into it, which makes "sin(pi/2)" mean radians.
    var hasPi = false
}

/// What an expression came to.
public struct CalcMathResult: Sendable, Equatable {
    public var value: Double
    /// A percentage answer ("5 is what % of 20" = 25%): `value` is the percent (25), not the fraction.
    public var isPercent: Bool
    /// Nothing was worked out: a lone number ("42", "-5", "(7)", "10k"), which isn't worth an answer row.
    public var isTrivial: Bool
}

/// The math parser: recursive descent over `CalcLexer`'s tokens, with Soulver-style percentages ("20% of 50",
/// "50 + 10%", "10% off 80", "5 is what % of 20"), implicit multiplication ("2pi", "2(3+4)"), factorials,
/// functions with or without parentheses ("sqrt 16"), and trigonometry in degrees unless told otherwise.
/// Anything it doesn't understand, or that doesn't work out (1/0, sqrt(-1)), is nil; it never traps.
public enum CalcExpression {
    public static func evaluate(_ text: String, env: CalcEnvironment) -> CalcMathResult? {
        let cleaned = CalcText.clean(text, lowercased: false)
        guard !cleaned.isEmpty, cleaned.count <= 300,
              let tokens = CalcLexer.tokens(cleaned, format: env.format), !tokens.isEmpty, tokens.count <= 200
        else { return nil }
        var parser = CalcParser(tokens: tokens, angleMode: env.angleMode)
        guard let value = try? parser.statement(), value.number.isFinite else { return nil }
        let number = CalcFormat.clean(value.isPercent ? value.number * 100 : value.number)
        guard number.isFinite else { return nil }
        return CalcMathResult(value: number == 0 ? 0 : number, isPercent: value.isPercent,
                              isTrivial: parser.operations == 0)
    }
}

struct CalcParseError: Error {}

struct CalcParser {
    var tokens: [CalcToken]
    var i = 0
    let angleMode: CalcAngleMode
    /// How many things were worked out (operators, functions, constants, base literals): 0 means a lone number.
    var operations = 0
    private var depth = 0

    init(tokens: [CalcToken], angleMode: CalcAngleMode) {
        self.tokens = tokens
        self.angleMode = angleMode
    }

    static let constants: [String: Double] = [
        "pi": .pi, "tau": 2 * .pi, "e": M_E, "phi": (1 + 5.0.squareRoot()) / 2, "golden": (1 + 5.0.squareRoot()) / 2,
    ]

    static let functions: Set<String> = [
        "sqrt", "cbrt", "abs", "round", "floor", "ceil", "trunc", "sign", "ln", "log", "log10", "log2", "exp",
        "sin", "cos", "tan", "cot", "sec", "csc", "asin", "acos", "atan", "acot", "asec", "acsc",
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth", "sech", "csch", "asinh", "acosh", "atanh",
        "min", "max", "gcd", "lcm", "fact", "factorial", "avg", "average", "mean", "sum", "hypot", "atan2", "pow",
        "ncr", "npr", "choose",
    ]

    var peek: CalcToken? { i < tokens.count ? tokens[i] : nil }
    func peek(_ offset: Int) -> CalcToken? { i + offset < tokens.count ? tokens[i + offset] : nil }

    // MARK: Statements

    /// A whole question: a percentage question or an expression, with nothing left over.
    mutating func statement() throws -> CalcValue {
        if let value = try percentQuestion() { return value }
        let value = try additive()
        guard i == tokens.count else { throw CalcParseError() }
        return value
    }

    /// "5 is what % of 20", "what % of 20 is 5", "5 as a % of 20", "5 is 25% of what", "% change from 50 to 75".
    mutating func percentQuestion() throws -> CalcValue? {
        let words = tokens.map { $0.word ?? ($0.symbol.map { String($0) } ?? "#") }
        func find(_ pattern: [String], from: Int = 0) -> Int? {
            guard words.count - pattern.count >= from else { return nil }
            for start in from...(words.count - pattern.count)
            where (0..<pattern.count).allSatisfy({ words[start + $0] == pattern[$0] }) {
                return start
            }
            return nil
        }
        func ratio(_ part: CalcValue, _ whole: CalcValue) throws -> CalcValue {
            guard whole.number != 0 else { throw CalcParseError() }
            return CalcValue(number: part.number / whole.number, isPercent: true)
        }
        if let at = find(["is", "what", "%", "of"]) {
            operations += 1
            return try ratio(sub(0..<at), sub((at + 4)..<tokens.count))
        }
        if let at = find(["as", "a", "%", "of"]) ?? find(["as", "%", "of"]) {
            operations += 1
            let skip = words[at + 1] == "a" ? 4 : 3
            return try ratio(sub(0..<at), sub((at + skip)..<tokens.count))
        }
        if find(["what", "%", "of"]) == 0, let at = find(["is"], from: 3) {
            operations += 1
            return try ratio(sub(at + 1..<tokens.count), sub(3..<at))
        }
        if let at = find(["%", "of", "what"]), at + 3 == tokens.count, let isAt = find(["is"]), isAt < at {
            operations += 1
            let part = try sub(0..<isAt)
            let percent = try sub(isAt + 1..<at)
            guard percent.number != 0 else { throw CalcParseError() }
            return CalcValue(number: part.number / (percent.number / 100))
        }
        if words.count > 3, find(["%", "change"]) == 0 {
            let start = words[2] == "from" ? 3 : 2
            guard let to = find(["to"], from: start) else { throw CalcParseError() }
            operations += 1
            let from = try sub(start..<to)
            let target = try sub(to + 1..<tokens.count)
            guard from.number != 0 else { throw CalcParseError() }
            return CalcValue(number: (target.number - from.number) / abs(from.number), isPercent: true)
        }
        return nil
    }

    /// Evaluates a slice of the tokens on its own.
    private mutating func sub(_ range: Range<Int>) throws -> CalcValue {
        guard !range.isEmpty else { throw CalcParseError() }
        var parser = CalcParser(tokens: Array(tokens[range]), angleMode: angleMode)
        let value = try parser.additive()
        guard parser.i == parser.tokens.count else { throw CalcParseError() }
        operations += parser.operations
        return value
    }

    // MARK: Expressions

    mutating func additive() throws -> CalcValue {
        var left = try multiplicative()
        while let c = peek?.symbol, c == "+" || c == "-" {
            i += 1
            let right = try multiplicative()
            operations += 1
            let sign: Double = c == "+" ? 1 : -1
            if right.isPercent, !left.isPercent {
                // 50 + 10% = 55, 50 - 10% = 45.
                left = CalcValue(number: left.number * (1 + sign * right.number), hasPi: left.hasPi)
            } else {
                left = CalcValue(number: left.number + sign * right.number, isPercent: left.isPercent && right.isPercent,
                                 angle: left.angle ?? right.angle, hasPi: left.hasPi || right.hasPi)
            }
        }
        return left
    }

    mutating func multiplicative() throws -> CalcValue {
        var left = try unary()
        while let token = peek {
            enum Op { case multiply, divide, modulo }
            let op: Op
            var implicit = false
            if token.symbol == "*" || token.word == "x" {
                op = .multiply
                i += 1
            } else if token.symbol == "/" {
                op = .divide
                i += 1
            } else if token.word == "mod" || (token.symbol == "%" && startsOperand(at: i + 1)) {
                op = .modulo
                i += 1
            } else if implicitMultiplication(at: i) {
                op = .multiply
                implicit = true
            } else {
                break
            }
            let right = implicit ? try power() : try unary()
            operations += 1
            let hasPi = left.hasPi || right.hasPi
            switch op {
            case .multiply:
                left = CalcValue(number: left.number * right.number, isPercent: left.isPercent,
                                 angle: left.angle ?? right.angle, hasPi: hasPi)
            case .divide:
                guard right.number != 0 else { throw CalcParseError() }
                left = CalcValue(number: left.number / right.number, isPercent: left.isPercent && !right.isPercent,
                                 angle: left.angle, hasPi: hasPi)
            case .modulo:
                guard right.number != 0 else { throw CalcParseError() }
                left = CalcValue(number: fmod(left.number, right.number), hasPi: hasPi)
            }
        }
        return left
    }

    mutating func unary() throws -> CalcValue {
        if let c = peek?.symbol, c == "-" || c == "+" {
            i += 1
            var value = try unary()
            if c == "-" { value.number = -value.number }
            return value
        }
        return try power()
    }

    mutating func power() throws -> CalcValue {
        let base = try postfix()
        guard peek?.symbol == "^" else { return base }
        i += 1
        let exponent = try unary()
        operations += 1
        let result = pow(base.number, exponent.number)
        guard result.isFinite else { throw CalcParseError() }
        return CalcValue(number: result, hasPi: base.hasPi || exponent.hasPi)
    }

    mutating func postfix() throws -> CalcValue {
        var value = try primary()
        while let token = peek {
            if token.symbol == "!" {
                i += 1
                operations += 1
                value = CalcValue(number: try Self.factorial(value.number))
            } else if token.symbol == "%", !startsOperand(at: i + 1) {
                i += 1
                value = CalcValue(number: value.number / 100, isPercent: true, hasPi: value.hasPi)
                if let word = peek?.word, ["of", "off", "on"].contains(word) {
                    i += 1
                    let whole = try multiplicative()
                    operations += 1
                    let fraction = value.number
                    switch word {
                    case "of": value = CalcValue(number: fraction * whole.number, hasPi: whole.hasPi)
                    case "off": value = CalcValue(number: whole.number * (1 - fraction), hasPi: whole.hasPi)
                    default: value = CalcValue(number: whole.number * (1 + fraction), hasPi: whole.hasPi)
                    }
                }
            } else if let word = token.word, word == "deg" || word == "rad" {
                i += 1
                value.angle = word == "deg" ? .degrees : .radians
            } else {
                break
            }
        }
        return value
    }

    mutating func primary() throws -> CalcValue {
        guard let token = peek else { throw CalcParseError() }
        switch token.kind {
        case .number(let x):
            i += 1
            if token.notation == .base { operations += 1 }
            return CalcValue(number: x)
        case .symbol("("):
            i += 1
            depth += 1
            guard depth < 24 else { throw CalcParseError() }
            let value = try additive()
            depth -= 1
            if peek?.symbol == ")" {
                i += 1
            } else if i < tokens.count {
                throw CalcParseError()
            }
            // An unclosed parenthesis at the end is fine while you type ("sqrt(16").
            return value
        case .word(let word):
            if let constant = Self.constants[word] {
                i += 1
                // A lone "e" or "phi" is more likely the start of a word than a question.
                if word == "pi" || word == "tau" || tokens.count > 1 { operations += 1 }
                return CalcValue(number: constant, hasPi: word == "pi" || word == "tau")
            }
            guard Self.functions.contains(word) else { throw CalcParseError() }
            i += 1
            operations += 1
            let arguments: [CalcValue]
            if peek?.symbol == "(" {
                i += 1
                depth += 1
                guard depth < 24 else { throw CalcParseError() }
                var list = [try additive()]
                while let c = peek?.symbol, c == "," || c == ";" {
                    i += 1
                    list.append(try additive())
                }
                depth -= 1
                if peek?.symbol == ")" {
                    i += 1
                } else if i < tokens.count {
                    throw CalcParseError()
                }
                arguments = list
            } else {
                // "sqrt 16", "sin 30", "√2".
                arguments = [try unary()]
            }
            return try CalcFunctions(angleMode: angleMode).call(word, arguments)
        default:
            throw CalcParseError()
        }
    }

    // MARK: Helpers

    /// Whether the token at `index` can begin an operand: a number, "(", a constant or a function.
    func startsOperand(at index: Int) -> Bool {
        guard index < tokens.count else { return false }
        switch tokens[index].kind {
        case .number: return true
        case .symbol(let c): return c == "("
        case .word(let w): return Self.constants[w] != nil || Self.functions.contains(w)
        }
    }

    /// "2pi", "2(3+4)", "(1+2)(3+4)", "2 sqrt 9", "(2)3" — but not "2 3".
    func implicitMultiplication(at index: Int) -> Bool {
        guard index > 0, index < tokens.count else { return false }
        let previous = tokens[index - 1]
        switch tokens[index].kind {
        case .symbol(let c): return c == "("
        case .word(let w): return Self.constants[w] != nil || Self.functions.contains(w)
        case .number: return previous.symbol == ")"
        }
    }

    static func factorial(_ n: Double) throws -> Double {
        guard n >= 0, n <= 170 else { throw CalcParseError() }
        if n == n.rounded() {
            var result = 1.0
            var k = 2.0
            while k <= n {
                result *= k
                k += 1
            }
            return result
        }
        return tgamma(n + 1)
    }
}

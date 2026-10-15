import Foundation

/// The calculator's functions. Trigonometry reads degrees unless the argument says "rad" (or uses π, as in
/// "sin(pi/2)"), and inverse functions answer in the same mode; values a hair from 0 or ±1 snap to them, so
/// sin 180 is 0 and tan 90 is an error rather than 1.6e16.
struct CalcFunctions {
    let angleMode: CalcAngleMode

    func call(_ name: String, _ args: [CalcValue]) throws -> CalcValue {
        let x = args.first?.number ?? .nan
        func one() throws -> Double {
            guard args.count == 1 else { throw CalcParseError() }
            return x
        }
        func checked(_ value: Double) throws -> CalcValue {
            guard value.isFinite else { throw CalcParseError() }
            return CalcValue(number: value)
        }
        switch name {
        case "sqrt":
            guard try one() >= 0 else { throw CalcParseError() }
            return try checked(x.squareRoot())
        case "cbrt": return try checked(cbrt(try one()))
        case "abs": return try checked(abs(try one()))
        case "sign": return try checked(try one() == 0 ? 0 : (x > 0 ? 1 : -1))
        case "floor": return try checked(floor(try one()))
        case "ceil": return try checked(ceil(try one()))
        case "trunc": return try checked(trunc(try one()))
        case "round":
            guard args.count == 1 || args.count == 2 else { throw CalcParseError() }
            let places = args.count == 2 ? args[1].number.rounded() : 0
            guard abs(places) <= 15 else { throw CalcParseError() }
            let scale = pow(10, places)
            return try checked((x * scale).rounded(.toNearestOrAwayFromZero) / scale)
        case "ln":
            guard try one() > 0 else { throw CalcParseError() }
            return try checked(log(x))
        case "log":
            guard x > 0, args.count == 1 || args.count == 2 else { throw CalcParseError() }
            if args.count == 2 {
                let base = args[1].number
                guard base > 0, base != 1 else { throw CalcParseError() }
                return try checked(log(x) / log(base))
            }
            return try checked(log10(x))
        case "log10":
            guard try one() > 0 else { throw CalcParseError() }
            return try checked(log10(x))
        case "log2":
            guard try one() > 0 else { throw CalcParseError() }
            return try checked(log2(x))
        case "exp": return try checked(exp(try one()))
        case "fact", "factorial": return try checked(CalcParser.factorial(try one()))
        case "sin", "cos", "tan", "cot", "sec", "csc":
            return try checked(trig(name, radians(try single(args))))
        case "asin", "acos", "atan", "acot", "asec", "acsc", "arcsin", "arccos", "arctan":
            return try checked(inverseTrig(name, try one()))
        case "atan2":
            guard args.count == 2 else { throw CalcParseError() }
            return try checked(fromRadians(atan2(args[0].number, args[1].number)))
        case "sinh": return try checked(sinh(try one()))
        case "cosh": return try checked(cosh(try one()))
        case "tanh": return try checked(tanh(try one()))
        case "coth": return try checked(1 / nonZero(tanh(try one())))
        case "sech": return try checked(1 / cosh(try one()))
        case "csch": return try checked(1 / nonZero(sinh(try one())))
        case "asinh": return try checked(asinh(try one()))
        case "acosh":
            guard try one() >= 1 else { throw CalcParseError() }
            return try checked(acosh(x))
        case "atanh":
            guard try one() > -1, x < 1 else { throw CalcParseError() }
            return try checked(atanh(x))
        case "min": return try checked(args.map(\.number).min() ?? .nan)
        case "max": return try checked(args.map(\.number).max() ?? .nan)
        case "sum": return try checked(args.map(\.number).reduce(0, +))
        case "avg", "average", "mean": return try checked(args.map(\.number).reduce(0, +) / Double(args.count))
        case "hypot":
            guard args.count == 2 else { throw CalcParseError() }
            return try checked(hypot(args[0].number, args[1].number))
        case "pow":
            guard args.count == 2 else { throw CalcParseError() }
            return try checked(pow(args[0].number, args[1].number))
        case "gcd", "lcm":
            let integers = try args.map { try integer($0.number) }
            var result = integers[0].magnitude
            for n in integers.dropFirst() {
                result = name == "gcd" ? Self.gcd(result, n.magnitude) : Self.lcm(result, n.magnitude)
            }
            return try checked(Double(result))
        case "ncr", "npr", "choose":
            guard args.count == 2 else { throw CalcParseError() }
            let n = try integer(args[0].number), k = try integer(args[1].number)
            guard n >= 0, k >= 0, k <= n, n <= 1000 else { throw CalcParseError() }
            var result = 1.0
            for j in 0..<Int(k) {
                result *= Double(n - Int64(j))
                if name != "npr" { result /= Double(j + 1) }
            }
            return try checked(result.rounded())
        default:
            throw CalcParseError()
        }
    }

    private func single(_ args: [CalcValue]) throws -> CalcValue {
        guard args.count == 1 else { throw CalcParseError() }
        return args[0]
    }

    private func nonZero(_ x: Double) throws -> Double {
        guard x != 0 else { throw CalcParseError() }
        return x
    }

    private func integer(_ x: Double) throws -> Int64 {
        guard x == x.rounded(), abs(x) < 9e15 else { throw CalcParseError() }
        return Int64(x)
    }

    static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    static func lcm(_ a: UInt64, _ b: UInt64) -> UInt64 {
        guard a != 0, b != 0 else { return 0 }
        let (product, overflow) = (a / gcd(a, b)).multipliedReportingOverflow(by: b)
        return overflow ? UInt64.max : product
    }

    // MARK: Trigonometry

    func radians(_ value: CalcValue) -> Double {
        let mode = value.angle ?? (value.hasPi ? .radians : angleMode)
        return mode == .degrees ? value.number * .pi / 180 : value.number
    }

    func fromRadians(_ r: Double) -> Double {
        angleMode == .degrees ? r * 180 / .pi : r
    }

    /// Rounds away the error that makes sin(π) 1.2e-16.
    static func snap(_ x: Double) -> Double {
        if abs(x) < 1e-12 { return 0 }
        for target in [1.0, -1.0, 0.5, -0.5] where abs(x - target) < 1e-12 { return target }
        return x
    }

    private func trig(_ name: String, _ r: Double) throws -> Double {
        let s = Self.snap(sin(r)), c = Self.snap(cos(r))
        switch name {
        case "sin": return s
        case "cos": return c
        case "tan": return s / (try nonZero(c))
        case "cot": return c / (try nonZero(s))
        case "sec": return 1 / (try nonZero(c))
        default: return 1 / (try nonZero(s))
        }
    }

    private func inverseTrig(_ name: String, _ x: Double) throws -> Double {
        let r: Double
        switch name {
        case "asin", "arcsin":
            guard abs(x) <= 1 else { throw CalcParseError() }
            r = asin(x)
        case "acos", "arccos":
            guard abs(x) <= 1 else { throw CalcParseError() }
            r = acos(x)
        case "atan", "arctan": r = atan(x)
        case "acot": r = x == 0 ? .pi / 2 : atan(1 / x)
        case "asec":
            guard abs(x) >= 1 else { throw CalcParseError() }
            r = acos(1 / x)
        default:
            guard abs(x) >= 1 else { throw CalcParseError() }
            r = asin(1 / x)
        }
        return fromRadians(r)
    }
}

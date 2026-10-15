import Foundation

/// How the calculator writes numbers: the locale's decimal and grouping marks, no binary float noise
/// (0.1 + 0.2 shows 0.3), at most 10 decimals, and scientific notation past a quadrillion or below 1e-7.
public struct CalcFormat: Sendable {
    public var locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    public var decimalSeparator: String { locale.decimalSeparator ?? "." }
    public var groupingSeparator: String { locale.groupingSeparator ?? "," }

    /// `x` rounded to 15 significant digits, which drops the noise binary floating point leaves behind.
    public static func clean(_ x: Double) -> Double {
        guard x.isFinite, x != 0 else { return x == 0 ? 0 : x }
        return Double(String(format: "%.15g", x)) ?? x
    }

    /// A math answer: grouped, up to `maxDecimals` decimals (fewer as the integer part grows, 15 digits in all).
    public func number(_ x: Double, maxDecimals: Int = 10, grouping: Bool = true) -> String {
        let value = Self.clean(x)
        guard value.isFinite else { return value.isNaN ? "NaN" : (value < 0 ? "-∞" : "∞") }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e15 || magnitude < 1e-7 { return scientific(value) }
        let integerDigits = magnitude >= 1 ? Int(log10(magnitude)) + 1 : 0
        let decimals = min(maxDecimals, max(0, 15 - integerDigits))
        return decimal(value, decimals: decimals, grouping: grouping)
    }

    /// A converted quantity: about 6 significant digits ("6.21371", "1,609.34", "0.0283495"), scientific from a
    /// trillion up.
    public func quantity(_ x: Double, significant: Int = 6) -> String {
        let value = Self.clean(x)
        guard value.isFinite else { return number(value) }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e12 || magnitude < 1e-9 { return scientific(value, digits: significant) }
        let decimals: Int
        if magnitude >= 1 {
            let integerDigits = Int(log10(magnitude)) + 1
            decimals = max(0, significant - integerDigits)
        } else {
            let leadingZeros = -Int(floor(log10(magnitude))) - 1
            decimals = min(12, leadingZeros + significant)
        }
        return decimal(value, decimals: decimals, grouping: true)
    }

    /// The number as you'd type it back: no grouping, the locale's decimal mark, full precision (up to 15 digits).
    public func raw(_ x: Double) -> String {
        number(x, maxDecimals: 15, grouping: false)
    }

    /// An amount of money in `code` ("€89.33", "R$ 100,00"): the currency's usual decimals, more for amounts under 1.
    public func currency(_ x: Double, code: String) -> String {
        let value = Self.clean(x)
        guard value.isFinite else { return number(value) }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        let magnitude = abs(value)
        if magnitude > 0, magnitude < 1 {
            let leadingZeros = -Int(floor(log10(magnitude))) - 1
            formatter.maximumFractionDigits = min(10, max(formatter.maximumFractionDigits, leadingZeros + 4))
        }
        if magnitude >= 1e15 { return "\(scientific(value)) \(code)" }
        return formatter.string(from: NSNumber(value: value)) ?? "\(number(value)) \(code)"
    }

    /// An integer with grouping ("1,234,567").
    public func integer(_ x: Int) -> String {
        decimal(Double(x), decimals: 0, grouping: true)
    }

    func decimal(_ value: Double, decimals: Int, grouping: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = decimals
        formatter.roundingMode = .halfUp
        var text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        // A value that rounds to zero would show as "-0".
        if text.hasPrefix("-"), Double(text.dropFirst().filter { $0.isNumber }) == 0 { text.removeFirst() }
        return text
    }

    /// "1.2345678901e+20": at most `digits` significant digits, the locale's decimal mark.
    func scientific(_ value: Double, digits: Int = 11) -> String {
        let text = String(format: "%.\(max(0, digits - 1))e", value)
        guard let e = text.firstIndex(of: "e") else { return text }
        var mantissa = String(text[..<e])
        if mantissa.contains(".") {
            while mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
        }
        var exponent = String(text[text.index(after: e)...])
        let sign = exponent.first == "-" ? "-" : "+"
        exponent = String(exponent.drop { $0 == "+" || $0 == "-" || $0 == "0" })
        if exponent.isEmpty { exponent = "0" }
        return mantissa.replacingOccurrences(of: ".", with: decimalSeparator) + "e\(sign)\(exponent)"
    }
}

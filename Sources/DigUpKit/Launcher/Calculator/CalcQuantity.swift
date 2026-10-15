import Foundation

/// One part of a typed quantity: "5 ft", "+ 500 m", "+ 47%".
struct CalcTerm {
    /// Signed: "- 500 m" is -500.
    var value: Double
    /// What the unit could be ("pound" is a weight or a currency); empty for a bare number.
    var candidates: [CalcUnit]
    var isPercent = false
    /// Joined with + or - ("10 km + 500 m") rather than written side by side ("5 ft 11 in").
    var added = false
    /// The unit picked once the other side of the conversion is known.
    var unit: CalcUnit?
}

/// A typed quantity: one or more terms ("5 ft 11 in", "10 km + 500 m", "19 m + 47%", "$100", "USD1K",
/// "8 dollars/hour").
struct CalcQuantity {
    var terms: [CalcTerm]
    /// The rate's time unit for "8 dollars/hour".
    var per: CalcUnit?
    /// A "k" was read as kelvin rather than thousand ("300K in C"), which only makes sense with a target.
    var kelvinFromShorthand = false
}

/// Reads quantities and unit names, with case-sensitive names first ("Mb" is a megabit), then the longest alias that
/// fits, so "fl oz" wins over "oz" and "km/h" over "km".
struct CalcUnitScanner {
    let rates: CalcRates?
    let decimalComma: Bool
    private let currencyAliases: [(String, String)]

    init(env: CalcEnvironment) {
        rates = env.rates
        decimalComma = env.format.decimalSeparator == ","
        currencyAliases = env.rates.map { CalcCurrency.scanAliases(rates: $0) } ?? []
    }

    private static let sortedAliases: [(alias: [Character], ids: [String])] = CalcUnitTable.aliases
        .map { (Array($0.key), $0.value) }
        .sorted { $0.alias.count > $1.alias.count }

    private static let sortedExact: [(alias: [Character], id: String)] = CalcUnitTable.exactAliases
        .map { (Array($0.key), $0.value) }
        .sorted { $0.alias.count > $1.alias.count }

    // MARK: Units

    /// The unit names that start at `p`, and how many characters they take.
    func unit(in chars: [Character], lower: [Character], at p: Int,
              currencies: Bool = true) -> (candidates: [CalcUnit], length: Int)? {
        func fits(_ alias: [Character], in text: [Character]) -> Bool {
            guard p + alias.count <= text.count else { return false }
            for k in 0..<alias.count where text[p + k] != alias[k] { return false }
            let end = p + alias.count
            guard end < text.count else { return true }
            // A word must end where the alias does ("m" isn't the start of "miles"); symbols needn't.
            return !(alias.last?.isLetter ?? false) || !text[end].isLetter
        }
        for (alias, id) in Self.sortedExact where fits(alias, in: chars) {
            if let unit = CalcUnitTable.units[id] { return ([unit], alias.count) }
        }
        var best: (candidates: [CalcUnit], length: Int)?
        for (alias, ids) in Self.sortedAliases where fits(alias, in: lower) {
            best = (ids.compactMap { CalcUnitTable.units[$0] }, alias.count)
            break
        }
        if currencies, let rates {
            for (alias, code) in currencyAliases where alias.count >= (best?.length ?? 0) {
                if fits(Array(alias), in: lower), let unit = CalcCurrency.unit(code, rates: rates) {
                    if let found = best, found.length == alias.count {
                        best = (found.candidates + [unit], alias.count)
                    } else {
                        best = ([unit], alias.count)
                    }
                    break
                }
            }
        }
        return best
    }

    /// A whole string as a unit name ("miles", "km/h", "€"), nil unless all of it is one.
    func unitName(_ text: String) -> [CalcUnit]? {
        let chars = Array(text)
        let lower = Self.lowered(chars)
        guard let found = unit(in: chars, lower: lower, at: 0), found.length == chars.count else { return nil }
        return found.candidates
    }

    static func lowered(_ chars: [Character]) -> [Character] {
        chars.map { c in
            let lower = c.lowercased()
            return lower.count == 1 ? Character(lower) : c
        }
    }

    // MARK: Quantities

    /// Reads `text` as a quantity, nil if any of it isn't one.
    func quantity(_ text: String) -> CalcQuantity? {
        let chars = Array(text)
        let lower = Self.lowered(chars)
        var p = 0
        var terms: [CalcTerm] = []
        var per: CalcUnit?
        var kelvinFromShorthand = false
        func skipSpaces() { while p < chars.count, chars[p] == " " { p += 1 } }
        skipSpaces()
        while p < chars.count {
            var sign = 1.0
            var added = false
            if chars[p] == "+" || chars[p] == "-" {
                sign = chars[p] == "-" ? -1 : 1
                added = !terms.isEmpty
                p += 1
                skipSpaces()
                guard p < chars.count else { return nil }
            } else if !terms.isEmpty, !chars[p].isASCIIDigit, chars[p] != "." {
                return nil
            }
            // "$100", "USD 1K", "R$ 50".
            var prefix: CalcUnit?
            if !chars[p].isASCIIDigit, let found = unit(in: chars, lower: lower, at: p),
               let currency = found.candidates.first(where: { $0.category == .currency }) {
                var q = p + found.length
                while q < chars.count, chars[q] == " " { q += 1 }
                if q < chars.count, chars[q].isASCIIDigit || chars[q] == "." {
                    prefix = currency
                    p = q
                }
            }
            guard p < chars.count, chars[p].isASCIIDigit || chars[p] == "." || chars[p] == ",",
                  let (scanned, notation, next) = CalcLexer.scanNumber(chars, from: p, decimalComma: decimalComma)
            else { return nil }
            var value = scanned
            p = next
            if notation == .base { return nil }
            if notation == .shorthand, prefix == nil {
                // "10k usd" is ten thousand dollars, but "300K" is 300 kelvin.
                var q = p
                while q < chars.count, chars[q] == " " { q += 1 }
                let followedByCurrency = unit(in: chars, lower: lower, at: q)?.candidates
                    .contains { $0.category == .currency } ?? false
                if !followedByCurrency, chars[p - 1] == "k" || chars[p - 1] == "K" {
                    value /= 1e3
                    p -= 1
                    kelvinFromShorthand = true
                }
            }
            // Fractions: "1/2 cup", "1 1/2 cups".
            if p < chars.count, chars[p] == "/", let (denominator, end) = digits(chars, at: p + 1) {
                guard denominator != 0 else { return nil }
                value /= denominator
                p = end
            } else if p < chars.count, chars[p] == " ", let (fraction, end) = fraction(chars, at: p + 1),
                      fraction < 1 {
                value += fraction
                p = end
            }
            var term = CalcTerm(value: sign * value, candidates: prefix.map { [$0] } ?? [], added: added)
            var q = p
            if q < chars.count, chars[q] == " " { q += 1 }
            if prefix == nil, q < chars.count, chars[q] == "%" {
                guard !terms.isEmpty else { return nil }
                term.isPercent = true
                p = q + 1
            } else if prefix == nil, let found = unit(in: chars, lower: lower, at: q) {
                term.candidates = found.candidates
                p = q + found.length
            }
            // "8 dollars/hour", "15 usd per hour".
            if term.candidates.contains(where: { $0.category == .currency }), let (unit, end) = perUnit(chars, lower, p) {
                per = unit
                p = end
            }
            terms.append(term)
            skipSpaces()
            if p < chars.count, lower[p] == "a", p + 3 < chars.count, String(lower[p...(p + 3)]) == "and " {
                p += 4
            }
        }
        // Every term needs a unit, except a percentage at the end ("19 m + 47%").
        guard !terms.isEmpty,
              terms.enumerated().allSatisfy({ !$1.candidates.isEmpty || ($1.isPercent && $0 == terms.count - 1) })
        else { return nil }
        return CalcQuantity(terms: terms, per: per, kelvinFromShorthand: kelvinFromShorthand)
    }

    /// "/hour", "/h", " per hour", " an hour", " a day" after a rate.
    func perUnit(_ chars: [Character], _ lower: [Character], _ p: Int) -> (CalcUnit, Int)? {
        var q = p
        if q < chars.count, chars[q] == "/" {
            q += 1
        } else {
            let rest = String(lower[p...])
            guard let word = [" per ", " an ", " a "].first(where: { rest.hasPrefix($0) }) else { return nil }
            q += word.count
        }
        guard let found = unit(in: chars, lower: lower, at: q, currencies: false),
              let duration = found.candidates.first(where: { $0.category == .duration }) else { return nil }
        return (duration, q + found.length)
    }

    /// "1/2" at `p`, as a value and where it ends.
    private func fraction(_ chars: [Character], at p: Int) -> (Double, Int)? {
        guard let (n, slash) = digits(chars, at: p), slash < chars.count, chars[slash] == "/",
              let (d, end) = digits(chars, at: slash + 1), d != 0 else { return nil }
        return (n / d, end)
    }

    /// A run of plain digits at `p` (not followed by a decimal mark), as a value and where it ends.
    private func digits(_ chars: [Character], at p: Int) -> (Double, Int)? {
        var q = p
        while q < chars.count, chars[q].isASCIIDigit { q += 1 }
        guard q > p, q == chars.count || (chars[q] != "." && chars[q] != ","),
              let value = Double(String(chars[p..<q])) else { return nil }
        return (value, q)
    }
}

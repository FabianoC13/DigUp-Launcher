import Foundation

/// Unit and currency conversions: "10 km in miles", "5'11\" in cm", "100 f to c", "2 lb 3 oz in kg",
/// "500 sqft in m2", "2rem in px", "2 inches in px at 72 ppi", "100 usd in eur", "$100 to €", "8 dollars/hour in gbp",
/// "145 mins to timespan", "55h in workdays", and bare quantities ("10 km", "37c", "100 eur") to their usual
/// counterpart.
public enum CalcConversion {
    enum Target {
        case units([CalcUnit], per: CalcUnit?)
        case timespan, workdays, workweeks, feetInches, poundsOunces
    }

    static let separators = ["in", "to", "into", "as", "=", "->", "→"]

    public static func answer(_ input: String, env: CalcEnvironment) -> CalcAnswer? {
        var text = CalcText.clean(input, lowercased: false)
        guard !text.isEmpty, text.count <= 120, text.contains(where: \.isASCIIDigit) else { return nil }
        // "2 inches in px at 72 ppi".
        var ppi = 96.0
        let words = text.split(separator: " ")
        if words.count >= 4, ["ppi", "dpi"].contains(words[words.count - 1].lowercased()),
           words[words.count - 3].lowercased() == "at", let density = Double(words[words.count - 2]), density > 0 {
            ppi = density
            text = words.dropLast(3).joined(separator: " ")
        }
        let scanner = CalcUnitScanner(env: env)
        let chars = Array(text)
        let lower = CalcUnitScanner.lowered(chars)
        for (left, right) in splits(chars, lower) {
            guard let target = target(right, scanner: scanner), let quantity = scanner.quantity(left) else { continue }
            if let answer = convert(quantity, to: target, env: env, ppi: ppi) { return answer }
        }
        guard let quantity = scanner.quantity(text) else { return nil }
        return bare(quantity, env: env, ppi: ppi)
    }

    /// Every way to cut the text at a separator word, rightmost first.
    static func splits(_ chars: [Character], _ lower: [Character]) -> [(String, String)] {
        var found: [(Int, Int)] = []
        for separator in separators {
            let needle = Array(" \(separator) ")
            guard lower.count > needle.count else { continue }
            for start in 1..<(lower.count - needle.count) where Array(lower[start..<(start + needle.count)]) == needle {
                found.append((start, start + needle.count))
            }
        }
        return found.sorted { $0.0 > $1.0 }.map { (String(chars[..<$0.0]), String(chars[$0.1...])) }
    }

    static func target(_ text: String, scanner: CalcUnitScanner) -> Target? {
        let lower = text.lowercased()
        switch lower {
        case "timespan", "time span", "readable", "human", "duration", "hms": return .timespan
        case "workdays", "work days", "workday", "work day", "business days", "working days": return .workdays
        case "workweeks", "work weeks", "workweek", "work week": return .workweeks
        case "ft in", "ft and in", "feet and inches", "feet inches", "ft+in", "ft/in", "ft'in": return .feetInches
        case "lb oz", "lbs oz", "lb and oz", "pounds and ounces", "pounds ounces": return .poundsOunces
        default: break
        }
        if let units = scanner.unitName(text) { return .units(units, per: nil) }
        // "gbp/hour", "eur per day".
        let chars = Array(text)
        let lowered = CalcUnitScanner.lowered(chars)
        if let found = scanner.unit(in: chars, lower: lowered, at: 0),
           let currency = found.candidates.first(where: { $0.category == .currency }),
           let (per, end) = scanner.perUnit(chars, lowered, found.length), end == chars.count {
            return .units([currency], per: per)
        }
        return nil
    }

    // MARK: Converting

    /// Picks each term's unit so they all measure one thing that can become `target`.
    static func resolve(_ quantity: CalcQuantity, toward target: [CalcUnit]?) -> (CalcQuantity, CalcUnitCategory)? {
        func attempt(_ quantity: CalcQuantity) -> (CalcQuantity, CalcUnitCategory)? {
            let unitTerms = quantity.terms.filter { !$0.isPercent }
            guard let first = unitTerms.first else { return nil }
            for category in first.candidates.map(\.category) {
                guard unitTerms.allSatisfy({ $0.candidates.contains { $0.category == category } }) else { continue }
                if let target, !target.contains(where: { compatible(category, $0.category) }) { continue }
                var resolved = quantity
                for index in resolved.terms.indices where !resolved.terms[index].isPercent {
                    resolved.terms[index].unit = resolved.terms[index].candidates.first { $0.category == category }
                }
                return (resolved, category)
            }
            return nil
        }
        if let found = attempt(quantity) { return found }
        // "1h 30m": an m among times is minutes.
        guard let minutes = CalcUnitTable.units["min"] else { return nil }
        var withMinutes = quantity
        for index in withMinutes.terms.indices where withMinutes.terms[index].candidates.contains(where: { $0.id == "m" }) {
            withMinutes.terms[index].candidates.append(minutes)
        }
        return attempt(withMinutes)
    }

    static func compatible(_ a: CalcUnitCategory, _ b: CalcUnitCategory) -> Bool {
        a == b || (a == .screen && b == .length) || (a == .length && b == .screen)
    }

    static func toBase(_ value: Double, _ unit: CalcUnit, env: CalcEnvironment) -> Double {
        if unit.category == .screen, unit.id != "px" { return value * env.remBase }
        return value * unit.factor + unit.offset
    }

    static func fromBase(_ value: Double, _ unit: CalcUnit, env: CalcEnvironment) -> Double {
        if unit.category == .screen, unit.id != "px" { return value / env.remBase }
        return (value - unit.offset) / unit.factor
    }

    /// The quantity in its category's base unit, nil for sums that make no sense (adding temperatures).
    static func total(_ quantity: CalcQuantity, category: CalcUnitCategory, env: CalcEnvironment) -> Double? {
        let unitTerms = quantity.terms.filter { !$0.isPercent }
        if category == .temperature, quantity.terms.count > 1 { return nil }
        var sum = 0.0
        for term in unitTerms {
            guard let unit = term.unit else { return nil }
            sum += toBase(term.value, unit, env: env)
        }
        if let percent = quantity.terms.last, percent.isPercent { sum *= 1 + percent.value / 100 }
        return sum.isFinite ? sum : nil
    }

    static func convert(_ quantity: CalcQuantity, to target: Target, env: CalcEnvironment, ppi: Double) -> CalcAnswer? {
        switch target {
        case .units(let candidates, let per):
            guard let (resolved, category) = resolve(quantity, toward: candidates),
                  let unit = candidates.first(where: { compatible(category, $0.category) }),
                  var base = total(resolved, category: category, env: env) else { return nil }
            // Pixels and physical lengths meet at a density: 96 px per inch unless "at 72 ppi".
            if category == .screen, unit.category == .length {
                base = base / ppi * 0.0254
            } else if category == .length, unit.category == .screen {
                base = base / 0.0254 * ppi
            }
            var value = fromBase(base, unit, env: env)
            if let from = resolved.per {
                value *= (per ?? from).factor / from.factor
            }
            guard value.isFinite else { return nil }
            return answer(resolved, category: category, value: value, unit: unit, per: per ?? resolved.per, env: env)
        case .timespan, .workdays, .workweeks:
            guard let (resolved, category) = resolve(quantity, toward: nil), category == .duration,
                  let seconds = total(resolved, category: category, env: env) else { return nil }
            let result: String
            let number: Double
            switch target {
            case .timespan:
                result = timespan(seconds, format: env.format)
                number = seconds
            case .workdays:
                number = seconds / (8 * 3600)
                result = "\(env.format.quantity(number)) \(number == 1 ? "workday" : "workdays")"
            default:
                number = seconds / (40 * 3600)
                result = "\(env.format.quantity(number)) \(number == 1 ? "workweek" : "workweeks")"
            }
            let label = target.label
            return CalcAnswer(kind: .unit, result: result, expression: "\(describe(resolved, env: env)) → \(label)",
                              caption: target.caption, number: env.format.raw(number))
        case .feetInches, .poundsOunces:
            let isLength = { if case .feetInches = target { true } else { false } }()
            guard let (resolved, category) = resolve(quantity, toward: nil),
                  category == (isLength ? .length : .mass),
                  let base = total(resolved, category: category, env: env) else { return nil }
            let result = isLength ? feetInches(meters: base, format: env.format)
                : poundsOunces(kilograms: base, format: env.format)
            return CalcAnswer(kind: .unit, result: result,
                              expression: "\(describe(resolved, env: env)) → \(isLength ? "ft in" : "lb oz")")
        }
    }

    static func bare(_ quantity: CalcQuantity, env: CalcEnvironment, ppi: Double) -> CalcAnswer? {
        // A lone "10K" is ten thousand, not 10 kelvin.
        guard !quantity.kelvinFromShorthand, let (resolved, category) = resolve(quantity, toward: nil),
              let first = resolved.terms.first?.unit else { return nil }
        let isSum = resolved.terms.count > 1
        let hasPercent = resolved.terms.last?.isPercent == true
        let target: CalcUnit
        if category == .currency, let rates = env.rates {
            var code = env.defaultCurrency
            if code == first.id || !rates.has(code) { code = first.id == "USD" ? "EUR" : "USD" }
            guard !isSum || hasPercent || code != first.id, let unit = CalcCurrency.unit(code, rates: rates)
            else { return nil }
            target = hasPercent ? first : unit
        } else if hasPercent {
            target = first
        } else if let id = CalcUnitTable.counterparts[first.id], let unit = CalcUnitTable.units[id] {
            target = unit
        } else if isSum {
            target = first
        } else {
            return nil
        }
        return convert(resolved, to: .units([target], per: nil), env: env, ppi: ppi)
    }

    // MARK: Writing answers

    static func answer(_ quantity: CalcQuantity, category: CalcUnitCategory, value: Double, unit: CalcUnit,
                       per: CalcUnit?, env: CalcEnvironment) -> CalcAnswer {
        let format = env.format
        let result = show(value, unit, per: per, format: format)
        let source = describe(quantity, env: env)
        let targetName = unit.category == .currency ? unit.id : unit.symbol(for: 2)
        let expression = "\(source) → \(targetName)\(per.map { "/\($0.symbol)" } ?? "")"
        var caption: String
        var alternatives: [CalcAlternative] = []
        if category == .currency, let rates = env.rates {
            let from = quantity.terms.first?.unit?.id ?? unit.id
            let rate = rates.convert(1, from: from, to: unit.id) ?? 0
            caption = "1 \(from) = \(format.quantity(rate, significant: 5)) \(unit.id) · ECB rates of "
                + rates.displayDate(locale: env.locale)
        } else if quantity.terms.count == 1, let from = quantity.terms[0].unit {
            caption = "\(format.number(quantity.terms[0].value)) \(from.name) = \(format.quantity(value)) \(unit.name)"
        } else {
            caption = "\(source) = \(result)"
        }
        if unit.id == "ft" || unit.id == "in" {
            let meters = toBase(value, unit, env: env)
            alternatives.append(CalcAlternative("Feet and inches", feetInches(meters: meters, format: format)))
            if quantity.terms.count == 1 { caption += " · \(feetInches(meters: meters, format: format))" }
        }
        return CalcAnswer(kind: category == .currency ? .currency : .unit, result: result, expression: expression,
                          caption: caption, number: format.raw(value), alternatives: alternatives)
    }

    static func show(_ value: Double, _ unit: CalcUnit, per: CalcUnit? = nil, format: CalcFormat) -> String {
        if unit.category == .currency {
            return format.currency(value, code: unit.id) + (per.map { "/\($0.symbol)" } ?? "")
        }
        let symbol = unit.symbol(for: value)
        let number = format.quantity(value)
        return symbol.hasPrefix("°") ? number + symbol : "\(number) \(symbol)"
    }

    /// The quantity as the calculator read it: "5 ft 11 in", "10 km + 500 m", "19 m + 47%", "100 USD/h".
    static func describe(_ quantity: CalcQuantity, env: CalcEnvironment) -> String {
        let format = env.format
        var text = ""
        for (index, term) in quantity.terms.enumerated() {
            let magnitude = index == 0 ? term.value : abs(term.value)
            if index > 0 { text += term.value < 0 ? " - " : (term.added ? " + " : " ") }
            if term.isPercent {
                text += format.number(magnitude) + "%"
            } else if let unit = term.unit {
                let symbol = unit.category == .currency ? unit.id : unit.symbol(for: magnitude)
                text += symbol.hasPrefix("°") ? format.number(magnitude) + symbol : "\(format.number(magnitude)) \(symbol)"
            } else {
                text += format.number(magnitude)
            }
        }
        if let per = quantity.per { text += "/\(per.symbol)" }
        return text
    }

    /// "2 hours, 25 minutes".
    static func timespan(_ seconds: Double, format: CalcFormat) -> String {
        guard seconds.isFinite else { return "" }
        if abs(seconds) < 1 { return "\(format.quantity(seconds * 1000)) milliseconds" }
        var rest = Int(abs(seconds).rounded())
        var parts: [String] = []
        for (name, size) in [("year", 31_556_952), ("day", 86400), ("hour", 3600), ("minute", 60), ("second", 1)] {
            let count = rest / size
            rest -= count * size
            if count > 0 { parts.append("\(format.integer(count)) \(name)\(count == 1 ? "" : "s")") }
        }
        return (seconds < 0 ? "-" : "") + parts.joined(separator: ", ")
    }

    /// "5 ft 10.87 in".
    static func feetInches(meters: Double, format: CalcFormat) -> String {
        let totalInches = meters / 0.0254
        var feet = (abs(totalInches) / 12).rounded(.down)
        var inches = ((abs(totalInches) - feet * 12) * 100).rounded() / 100
        if inches >= 12 {
            feet += 1
            inches -= 12
        }
        let sign = totalInches < 0 ? "-" : ""
        return "\(sign)\(format.integer(Int(feet))) ft \(format.number(inches, maxDecimals: 2)) in"
    }

    /// "4 lb 6.4 oz".
    static func poundsOunces(kilograms: Double, format: CalcFormat) -> String {
        let totalOunces = kilograms / 0.028349523125
        var pounds = (abs(totalOunces) / 16).rounded(.down)
        var ounces = ((abs(totalOunces) - pounds * 16) * 100).rounded() / 100
        if ounces >= 16 {
            pounds += 1
            ounces -= 16
        }
        let sign = totalOunces < 0 ? "-" : ""
        return "\(sign)\(format.integer(Int(pounds))) lb \(format.number(ounces, maxDecimals: 2)) oz"
    }
}

extension CalcConversion.Target {
    var label: String {
        switch self {
        case .timespan: "timespan"
        case .workdays: "workdays"
        case .workweeks: "workweeks"
        case .feetInches: "ft in"
        case .poundsOunces: "lb oz"
        case .units(let units, _): units.first?.symbol ?? ""
        }
    }

    var caption: String? {
        switch self {
        case .workdays: "8-hour workdays"
        case .workweeks: "40-hour workweeks"
        default: nil
        }
    }
}

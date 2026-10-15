import Foundation

/// An sRGB color with alpha, each 0…1, read from CSS notations and written back in all of them.
public struct CalcColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
        self.alpha = Self.unit(alpha)
    }

    static func unit(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }

    // MARK: Reading

    /// "#f80", "#ff8800cc", "rgb(255 136 0)", "rgba(255, 136, 0, 0.5)", "hsl(32 100% 50%)", "hwb(32 0% 0%)",
    /// "lab(…)", "lch(…)", "oklab(…)", "oklch(…)"; nil for anything else.
    public static func parse(_ input: String) -> CalcColor? {
        let text = input.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") { return hex(String(text.dropFirst())) }
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let name = text[..<open].trimmingCharacters(in: .whitespaces)
        let body = text[text.index(after: open)..<text.index(before: text.endIndex)]
        // Both "rgb(1, 2, 3, 0.5)" and "rgb(1 2 3 / 50%)".
        var parts = body.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "/", with: " / ")
            .split(separator: " ").map(String.init)
        var alphaText: String?
        if let slash = parts.firstIndex(of: "/") {
            guard slash + 2 == parts.count else { return nil }
            alphaText = parts[slash + 1]
            parts.removeSubrange(slash...)
        } else if parts.count == 4 {
            alphaText = parts.removeLast()
        }
        guard parts.count == 3 else { return nil }
        var alpha = 1.0
        if let alphaText {
            guard let a = number(alphaText, percentOf: 1) else { return nil }
            alpha = a
        }
        switch name {
        case "rgb", "rgba":
            guard let r = number(parts[0], percentOf: 255), let g = number(parts[1], percentOf: 255),
                  let b = number(parts[2], percentOf: 255) else { return nil }
            return CalcColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
        case "hsl", "hsla":
            guard let h = hue(parts[0]), let s = number(parts[1], percentOf: 1, plainIsPercent: true),
                  let l = number(parts[2], percentOf: 1, plainIsPercent: true) else { return nil }
            return hsl(h, s, l, alpha: alpha)
        case "hwb":
            guard let h = hue(parts[0]), let w = number(parts[1], percentOf: 1, plainIsPercent: true),
                  let b = number(parts[2], percentOf: 1, plainIsPercent: true) else { return nil }
            return hwb(h, w, b, alpha: alpha)
        case "lab":
            guard let l = number(parts[0], percentOf: 100), let a = number(parts[1], percentOf: 125),
                  let b = number(parts[2], percentOf: 125) else { return nil }
            return fromLab(l, a, b, alpha: alpha)
        case "lch":
            guard let l = number(parts[0], percentOf: 100), let c = number(parts[1], percentOf: 150),
                  let h = hue(parts[2]) else { return nil }
            return fromLab(l, c * cos(h * .pi / 180), c * sin(h * .pi / 180), alpha: alpha)
        case "oklab":
            guard let l = number(parts[0], percentOf: 1), let a = number(parts[1], percentOf: 0.4),
                  let b = number(parts[2], percentOf: 0.4) else { return nil }
            return fromOklab(l, a, b, alpha: alpha)
        case "oklch":
            guard let l = number(parts[0], percentOf: 1), let c = number(parts[1], percentOf: 0.4),
                  let h = hue(parts[2]) else { return nil }
            return fromOklab(l, c * cos(h * .pi / 180), c * sin(h * .pi / 180), alpha: alpha)
        default:
            return nil
        }
    }

    static func hex(_ digits: String) -> CalcColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let full = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
        guard let value = UInt64(full, radix: 16) else { return nil }
        let hasAlpha = full.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        return CalcColor(red: Double((value >> (16 + shift)) & 0xFF) / 255,
                         green: Double((value >> (8 + shift)) & 0xFF) / 255,
                         blue: Double((value >> shift) & 0xFF) / 255,
                         alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1)
    }

    /// "50%" → `percentOf` × 0.5, "0.5" → 0.5 (or 50% of `percentOf` when `plainIsPercent`, as in legacy hsl()).
    static func number(_ text: String, percentOf: Double, plainIsPercent: Bool = false) -> Double? {
        if text.hasSuffix("%") {
            guard let x = Double(text.dropLast()) else { return nil }
            return x / 100 * percentOf
        }
        if text == "none" { return 0 }
        guard let x = Double(text), x.isFinite else { return nil }
        return plainIsPercent ? x / 100 * percentOf : x
    }

    /// A hue in degrees: "120", "120deg", "0.5turn", "2rad".
    static func hue(_ text: String) -> Double? {
        let units: [(String, Double)] = [("deg", 1), ("grad", 0.9), ("rad", 180 / .pi), ("turn", 360)]
        for (suffix, scale) in units where text.hasSuffix(suffix) {
            return Double(text.dropLast(suffix.count)).map { $0 * scale }
        }
        if text == "none" { return 0 }
        return Double(text)
    }

    // MARK: Spaces

    static func hsl(_ hue: Double, _ s: Double, _ l: Double, alpha: Double = 1) -> CalcColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        func f(_ n: Double) -> Double {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            let a = s * min(l, 1 - l)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return CalcColor(red: f(0), green: f(8), blue: f(4), alpha: alpha)
    }

    static func hwb(_ hue: Double, _ white: Double, _ black: Double, alpha: Double = 1) -> CalcColor {
        if white + black >= 1 {
            let gray = white / (white + black)
            return CalcColor(red: gray, green: gray, blue: gray, alpha: alpha)
        }
        let base = hsl(hue, 1, 0.5)
        func mix(_ c: Double) -> Double { c * (1 - white - black) + white }
        return CalcColor(red: mix(base.red), green: mix(base.green), blue: mix(base.blue), alpha: alpha)
    }

    /// Hue (degrees), saturation and lightness (0…1).
    public var hslComponents: (h: Double, s: Double, l: Double) {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        guard d > 1e-12 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        switch maxC {
        case red: h = (green - blue) / d + (green < blue ? 6 : 0)
        case green: h = (blue - red) / d + 2
        default: h = (red - green) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    /// Hue (degrees), whiteness and blackness (0…1).
    public var hwbComponents: (h: Double, w: Double, b: Double) {
        (hslComponents.h, min(red, green, blue), 1 - max(red, green, blue))
    }

    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func gamma(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// CIE Lab with a D50 white point, as CSS's lab() uses.
    public var labComponents: (l: Double, a: Double, b: Double) {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        // Linear sRGB → XYZ (D65) → XYZ (D50, Bradford), with CSS Color 4's matrices.
        let x65 = 0.41239079926595 * r + 0.35758433938387 * g + 0.18048078840183 * b
        let y65 = 0.21263900587151 * r + 0.71516867876775 * g + 0.07219231536073 * b
        let z65 = 0.01933081871559 * r + 0.11919477979462 * g + 0.95053215224966 * b
        let x = 1.0479298208405488 * x65 + 0.022946793341019088 * y65 - 0.05019222954313557 * z65
        let y = 0.029627815688159344 * x65 + 0.990434484573249 * y65 - 0.01707382502938514 * z65
        let z = -0.009243058152591178 * x65 + 0.015055144896577895 * y65 + 0.7518742899580008 * z65
        let white = (0.3457 / 0.3585, 1.0, (1 - 0.3457 - 0.3585) / 0.3585)
        let epsilon = 216.0 / 24389, kappa = 24389.0 / 27
        func f(_ t: Double) -> Double { t > epsilon ? cbrt(t) : (kappa * t + 16) / 116 }
        let fx = f(x / white.0), fy = f(y / white.1), fz = f(z / white.2)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func fromLab(_ l: Double, _ a: Double, _ b: Double, alpha: Double = 1) -> CalcColor {
        let epsilon = 216.0 / 24389, kappa = 24389.0 / 27
        let white = (0.3457 / 0.3585, 1.0, (1 - 0.3457 - 0.3585) / 0.3585)
        let fy = (l + 16) / 116, fx = a / 500 + fy, fz = fy - b / 200
        let x = (pow(fx, 3) > epsilon ? pow(fx, 3) : (116 * fx - 16) / kappa) * white.0
        let y = (l > kappa * epsilon ? pow(fy, 3) : l / kappa) * white.1
        let z = (pow(fz, 3) > epsilon ? pow(fz, 3) : (116 * fz - 16) / kappa) * white.2
        let x65 = 0.9554734527042182 * x - 0.023098536874261423 * y + 0.0632593086610217 * z
        let y65 = -0.028369706963208136 * x + 1.0099954580058226 * y + 0.021041398966943008 * z
        let z65 = 0.012314001688319899 * x - 0.020507696433477912 * y + 1.3303659366080753 * z
        let r = 3.2409699419045226 * x65 - 1.537383177570094 * y65 - 0.4986107602930034 * z65
        let g = -0.9692436362808796 * x65 + 1.8759675015077202 * y65 + 0.04155505740717559 * z65
        let bl = 0.05563007969699366 * x65 - 0.20397695888897652 * y65 + 1.0569715142428786 * z65
        return CalcColor(red: gamma(r), green: gamma(g), blue: gamma(bl), alpha: alpha)
    }

    /// Björn Ottosson's Oklab.
    public var oklabComponents: (l: Double, a: Double, b: Double) {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func fromOklab(_ L: Double, _ a: Double, _ b: Double, alpha: Double = 1) -> CalcColor {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return CalcColor(red: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                         green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                         blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha: alpha)
    }

    static func polar(_ a: Double, _ b: Double) -> (c: Double, h: Double) {
        let c = (a * a + b * b).squareRoot()
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return (c, c < 1e-4 ? 0 : h)
    }
}

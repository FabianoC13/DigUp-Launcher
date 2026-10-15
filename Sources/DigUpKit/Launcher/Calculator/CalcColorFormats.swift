import Foundation

extension CalcColor {
    /// "#FF8800".
    public var hex: String {
        String(format: "#%02X%02X%02X", Self.byte(red), Self.byte(green), Self.byte(blue))
    }

    /// "#FF8800CC".
    public var hexAlpha: String { hex + String(format: "%02X", Self.byte(alpha)) }

    static func byte(_ c: Double) -> Int { Int((c * 255).rounded()) }

    /// Every notation "Copy Color as…" offers, in order.
    public var formats: [CalcAlternative] {
        let r = Self.byte(red), g = Self.byte(green), b = Self.byte(blue)
        let a = Self.code(alpha, 3)
        let alphaPercent = Self.code(alpha * 100, 1) + "%"
        let (h, s, l) = hslComponents
        let hue = Self.code(h, 1), sat = Self.code(s * 100, 1) + "%", light = Self.code(l * 100, 1) + "%"
        let (hw, white, black) = hwbComponents
        let lab = labComponents
        let lch = Self.polar(lab.a, lab.b)
        let ok = oklabComponents
        let oklch = Self.polar(ok.a, ok.b)
        let cr = Self.code(red, 3), cg = Self.code(green, 3), cb = Self.code(blue, 3)
        return [
            CalcAlternative("HEX", hex),
            CalcAlternative("HEX with Alpha", hexAlpha),
            CalcAlternative("RGBA", "rgba(\(r), \(g), \(b), \(a))"),
            CalcAlternative("RGBA Percentage", "rgba(\(Self.code(red * 100, 1))%, \(Self.code(green * 100, 1))%, "
                            + "\(Self.code(blue * 100, 1))%, \(a))"),
            CalcAlternative("RGB (CSS4)", "rgb(\(r) \(g) \(b) / \(alphaPercent))"),
            CalcAlternative("HSLA", "hsla(\(hue), \(sat), \(light), \(a))"),
            CalcAlternative("HSL (CSS4)", "hsl(\(hue) \(sat) \(light) / \(alphaPercent))"),
            CalcAlternative("HSV", hsvText),
            CalcAlternative("HWB", "hwb(\(Self.code(hw, 1)) \(Self.code(white * 100, 1))% "
                            + "\(Self.code(black * 100, 1))%\(alpha < 1 ? " / \(alphaPercent)" : ""))"),
            CalcAlternative("Lab", "lab(\(Self.code(lab.l, 2)) \(Self.code(lab.a, 2)) \(Self.code(lab.b, 2)))"),
            CalcAlternative("LCH", "lch(\(Self.code(lab.l, 2)) \(Self.code(lch.c, 2)) \(Self.code(lch.h, 2)))"),
            CalcAlternative("Oklab", "oklab(\(Self.code(ok.l, 4)) \(Self.code(ok.a, 4)) \(Self.code(ok.b, 4)))"),
            CalcAlternative("Oklch", "oklch(\(Self.code(ok.l, 4)) \(Self.code(oklch.c, 4)) \(Self.code(oklch.h, 2)))"),
            CalcAlternative("NSColor", "NSColor(srgbRed: \(cr), green: \(cg), blue: \(cb), alpha: \(a))"),
            CalcAlternative("UIColor", "UIColor(red: \(cr), green: \(cg), blue: \(cb), alpha: \(a))"),
            CalcAlternative("SwiftUI Color", "Color(red: \(cr), green: \(cg), blue: \(cb), opacity: \(a))"),
        ]
    }

    /// "hsv(32, 100%, 100%)".
    var hsvText: String {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        let s = maxC == 0 ? 0 : (maxC - minC) / maxC
        return "hsv(\(Self.code(hslComponents.h, 1)), \(Self.code(s * 100, 1))%, \(Self.code(maxC * 100, 1))%)"
    }

    /// A number for code and CSS: a dot, at most `digits` decimals, no trailing zeros.
    static func code(_ x: Double, _ digits: Int) -> String {
        var text = String(format: "%.\(digits)f", x)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}

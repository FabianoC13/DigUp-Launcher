import AppKit
import Observation

/// How see-through the panel is: Normal (DigUp's look) or Stealth, a fainter panel others notice less. Stealth's
/// three values are tuned live (`StealthTuner`, a page on localhost) or in Settings → Launcher.
@Observable
final class PanelAppearance {
    static let shared = PanelAppearance()

    struct Look: Codable, Equatable {
        /// The whole panel, text included (the window's alpha): 0.15…1.
        var opacity: Double
        /// The tint behind the text, over the blur: 0…1 (Normal: 0.75).
        var tint: Double
        /// The frosted blur of what's behind the panel.
        var blur: Bool

        static let normal = Look(opacity: 1, tint: 0.75, blur: true)
        static let stealthDefault = Look(opacity: 0.55, tint: 0.15, blur: false)
    }

    var stealth: Bool {
        didSet {
            AppSettings.defaults.set(stealth, forKey: "panel.stealth")
            changed()
        }
    }
    var stealthLook: Look {
        didSet {
            if let data = try? JSONEncoder().encode(stealthLook) { AppSettings.defaults.set(data, forKey: "panel.stealthLook") }
            changed()
        }
    }
    /// A look being tried (the tuning page's sliders), shown instead of the mode's until it's saved or dropped.
    var preview: Look? {
        didSet { changed() }
    }
    /// The tuning page is open: the panel stays up while the browser has the keyboard.
    var tuning = false

    /// What the panel draws now.
    var look: Look { preview ?? (stealth ? stealthLook : .normal) }

    /// Called when the look changes (the panel applies the window's alpha and the blur).
    @ObservationIgnored var onChange: [() -> Void] = []

    private init() {
        stealth = AppSettings.defaults.bool(forKey: "panel.stealth")
        stealthLook = AppSettings.defaults.data(forKey: "panel.stealthLook")
            .flatMap { try? JSONDecoder().decode(Look.self, from: $0) } ?? .stealthDefault
    }

    private func changed() {
        for observer in onChange { observer() }
    }
}

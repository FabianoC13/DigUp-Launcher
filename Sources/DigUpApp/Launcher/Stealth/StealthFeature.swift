import AppKit
import SwiftUI

/// Stealth mode: a fainter panel. Commands to switch it and to tune it on a localhost page; its part of Settings.
enum StealthFeature: LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] { [StealthProvider()] }

    static var settingsTitle: String? { "Stealth Mode" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(StealthSettingsView(appearance: PanelAppearance.shared, launcher: launcher))
    }
}

/// "Toggle Stealth Mode" and "Tune Stealth Mode…" (id prefix "stealth").
final class StealthProvider: LauncherProvider {
    let id = "stealth"

    private enum Command: String, CaseIterable {
        case toggle, tune

        var title: String {
            switch self {
            case .toggle: PanelAppearance.shared.stealth ? "Turn Off Stealth Mode" : "Turn On Stealth Mode"
            case .tune: "Tune Stealth Mode…"
            }
        }
        var keywords: [String] {
            switch self {
            case .toggle: ["stealth", "toggle stealth mode", "transparent", "transparency", "normal mode", "hide panel"]
            case .tune: ["stealth", "transparency", "opacity", "slider", "adjust stealth"]
            }
        }
        var symbol: String { self == .toggle ? "eye.slash" : "slider.horizontal.3" }
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        return Command.allCases.compactMap { command in
            query.match(command.title, keywords: command.keywords).map { item(command, score: $0) }
        }
    }

    func item(id: String) async -> LauncherItem? {
        Command(rawValue: String(id.dropFirst(self.id.count + 1))).map { item($0, score: 0.5) }
    }

    private func item(_ command: Command, score: Double) -> LauncherItem {
        let appearance = PanelAppearance.shared
        let look = appearance.stealthLook
        let summary = "Panel \(Int(look.opacity * 100))%, tint \(Int(look.tint * 100))%, blur \(look.blur ? "on" : "off")"
        switch command {
        case .toggle:
            return LauncherItem(
                id: "stealth:toggle", title: command.title,
                subtitle: appearance.stealth ? "Back to the normal panel" : summary,
                icon: .symbol(command.symbol), accessory: appearance.stealth ? "Stealth" : "Normal",
                score: score,
                actions: [LauncherAction(id: "toggle", title: command.title, symbol: command.symbol,
                                         keepsPanelOpen: true) { context in
                    appearance.stealth.toggle()
                    context.flash(appearance.stealth ? "Stealth mode on" : "Normal mode")
                    context.refresh()
                }])
        case .tune:
            return LauncherItem(
                id: "stealth:tune", title: command.title, subtitle: "Sliders on a page in your browser · \(summary)",
                icon: .symbol(command.symbol), accessory: "Stealth", score: score,
                actions: [LauncherAction(id: "tune", title: "Open the Tuning Page", symbol: "safari",
                                         keepsPanelOpen: true) { context in
                    guard let panel = context.launcher.panel else { return }
                    StealthTuner.shared.open(panel: panel)
                }])
        }
    }
}

private struct StealthSettingsView: View {
    @Bindable var appearance: PanelAppearance
    let launcher: Launcher

    var body: some View {
        Toggle(isOn: $appearance.stealth) {
            Text("Stealth mode")
            Text("A fainter panel that's harder to notice. Find it as “stealth” in the panel to switch quickly, or "
                 + "give that command a hotkey (⌘K → Set Hotkey…).")
        }
        LabeledContent("Whole panel") {
            Slider(value: $appearance.stealthLook.opacity, in: 0.15...1)
            Text("\(Int(appearance.stealthLook.opacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        LabeledContent("Background tint") {
            Slider(value: $appearance.stealthLook.tint, in: 0...1)
            Text("\(Int(appearance.stealthLook.tint * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        Toggle("Blur what's behind", isOn: $appearance.stealthLook.blur)
        LabeledContent("Live") {
            Button("Tune on a Page in the Browser…") {
                if let panel = launcher.panel { StealthTuner.shared.open(panel: panel) }
            }
        }
    }
}

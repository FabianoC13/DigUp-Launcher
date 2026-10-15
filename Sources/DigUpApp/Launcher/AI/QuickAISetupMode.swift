import AppKit
import DigUpKit
import SwiftUI

/// Quick AI before it can ask anything: no API key saved for the provider (or no base URL for one that needs it).
/// Says where the key goes; ↩ opens Settings → Launcher → Quick AI.
final class QuickAISetupMode: LauncherMode {
    /// What was typed before Tab, shown so it isn't lost from sight.
    let prompt: String

    init(prompt: String) {
        self.prompt = prompt
    }

    var title: String { "Quick AI" }
    var placeholder: String { "Add an API key in Settings to start asking…" }
    var icon: LauncherIcon { .symbol("sparkles") }
    var keysHint: String? { "↩ Open Settings   ⌘K Actions   Esc Back" }
    var statusHint: String? { "Not set up" }

    private var preset: AIProviderPreset { QuickAIPreferences.shared.provider }

    /// One invisible row whose actions are ⌘K's.
    func items(for query: LauncherQuery) async -> [LauncherItem] {
        var actions = [LauncherAction(id: "settings", title: "Open Quick AI Settings", symbol: "gearshape") {
            QuickAIFeature.openSettings($0)
        }]
        if let page = preset.keyPage.flatMap(URL.init(string:)) {
            actions.append(LauncherAction(id: "get-key", title: "Get a \(preset.name) API Key", symbol: "key") {
                $0.open(page)
            })
        }
        return [LauncherItem(id: "ai:setup", title: "Set Up Quick AI", icon: .symbol("sparkles"),
                             section: .named("Quick AI", order: 0), actions: actions, tracksUsage: false)]
    }

    func makeView(context: LauncherContext) -> AnyView? {
        AnyView(QuickAISetupView(preset: preset, prompt: prompt,
                                 openSettings: { [weak context] in QuickAIFeature.openSettings(context) },
                                 open: { [weak context] url in
                                     context?.hide()
                                     context?.open(url)
                                 }))
    }

    func handle(_ event: NSEvent, query: String, context: LauncherContext) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode == 36 || event.keyCode == 76, flags.isEmpty else { return false }
        QuickAIFeature.openSettings(context)
        return true
    }
}

private struct QuickAISetupView: View {
    let preset: AIProviderPreset
    let prompt: String
    let openSettings: () -> Void
    let open: (URL) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Brand.gradient)
            Text(preset.keyOptional ? "Point Quick AI at your server" : "Connect Quick AI to \(preset.name)")
                .font(.system(size: 16, weight: .semibold))
            Text(explanation)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open Settings  ↩", action: openSettings)
                if let page = preset.keyPage.flatMap(URL.init(string:)) {
                    Button("Get a Key") { open(page) }
                }
            }
            .controlSize(.large)
            if !prompt.isEmpty {
                Text("Then press Tab again to ask “\(prompt)”.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: 520)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var explanation: String {
        if preset.keyOptional {
            return "\(preset.name) needs the server's base URL (such as http://localhost:11434/v1). Add it in "
                + "Settings → Launcher → Quick AI."
        }
        return "Quick AI sends your questions to \(preset.name) with your own API key. Paste the key in Settings → "
            + "Launcher → Quick AI; it's kept in your login Keychain (“\(QuickAIKeys.service)”, account “\(preset.id)”), "
            + "never in a file."
    }
}

import AppKit
import SwiftUI

/// Settings → Launcher: each feature's section (`LauncherFeature.settingsView`), in `LauncherFeatures.all`'s order.
struct LauncherSettings: View {
    let launcher: Launcher

    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility") {
                    HStack {
                        Text(Accessibility.isTrusted() ? "Allowed" : "Not allowed yet")
                            .foregroundStyle(.secondary)
                        Button("Open Privacy Settings…") { Accessibility.openSettings() }
                    }
                }
            } footer: {
                Text("Pasting, window layouts, text expansion and menu items need DigUp in Privacy & Security → "
                     + "Accessibility.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(LauncherFeatures.all.enumerated()), id: \.offset) { _, feature in
                if let title = feature.settingsTitle {
                    Section(title) {
                        feature.settingsView(launcher)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

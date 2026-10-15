import AppKit
import DigUpKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Launcher → Applications: folders scanned for apps besides the standard ones, files in root search, and
/// Auto Quit's list. Rows of the launcher settings' Form section.
struct AppsSettingsView: View {
    let store: AppsPreferencesStore

    private var preferences: AppsPreferences { store.value }

    var body: some View {
        Toggle("Show files whose names match in root search", isOn: binding(\.filesInRootSearch))
        LabeledContent("App folders") {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(preferences.extraFolders, id: \.self) { folder in
                    HStack(spacing: 6) {
                        Text(AppsFormat.tildePath(folder, home: NSHomeDirectory()))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(FileManager.default.fileExists(atPath: folder) ? .primary : .secondary)
                        Button {
                            AppsFeature.updatePreferences { $0.extraFolders.removeAll { $0 == folder } }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop looking for apps here")
                    }
                }
                Button("Add Folder…", action: addFolder)
            }
        }
        Text("/Applications, ~/Applications and macOS's own apps are always searched, and Spotlight finds apps "
            + "elsewhere. Added folders are searched three levels deep.")
            .font(.caption).foregroundStyle(.secondary)

        Toggle("Auto Quit apps that sit in the background", isOn: binding(\.autoQuitEnabled))
        if preferences.autoQuitEnabled {
            Picker("Quit after", selection: binding(\.autoQuitMinutes)) {
                ForEach(AppsAutoQuit.durations, id: \.self) { minutes in
                    Text(AppsAutoQuit.durationText(minutes)).tag(minutes)
                }
            }
            ForEach(preferences.autoQuitApps) { rule in
                AppsAutoQuitRow(rule: rule, defaultMinutes: preferences.autoQuitMinutes)
            }
            HStack {
                Spacer()
                Menu("Add Running App") {
                    ForEach(runningCandidates, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") { add(app) }
                    }
                }
                .fixedSize()
                .disabled(runningCandidates.isEmpty)
                Button("Add App…", action: chooseApp)
            }
            Text("Being in front resets an app's clock. Apps are asked to quit like ⌘Q, so unsaved work is never "
                + "lost, and nothing quits while a microphone is in use or, for music and video players, while "
                + "sound plays. You can also turn it on for an app from its actions (⌘K) in the launcher.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppsPreferences, Value>) -> Binding<Value> {
        Binding(get: { store.value[keyPath: keyPath] },
                set: { value in AppsFeature.updatePreferences { $0[keyPath: keyPath] = value } })
    }

    /// Running apps that aren't on the list yet.
    private var runningCandidates: [NSRunningApplication] {
        let listed = Set(preferences.autoQuitApps.map(\.bundleID))
        return AppsRunning.regularApps().filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return !listed.contains(id) && !AppsAutoQuit.neverQuit.contains(id)
        }
    }

    private func add(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        AppsFeature.updatePreferences {
            $0.setAutoQuit(bundleID: id, name: app.localizedName ?? id, minutes: nil)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to quit automatically"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var skipped: [String] = []
        for url in panel.urls {
            let name = AppsScanner.displayName(url.path)
            guard let id = Bundle(url: url)?.bundleIdentifier, !AppsAutoQuit.neverQuit.contains(id) else {
                skipped.append(name)
                continue
            }
            AppsFeature.updatePreferences { $0.setAutoQuit(bundleID: id, name: name, minutes: nil) }
        }
        if !skipped.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Auto Quit can't quit \(skipped.joined(separator: ", "))."
            alert.informativeText = "Finder and DigUp itself are never quit, and an app needs a bundle identifier."
            alert.runModal()
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder with apps"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        AppsFeature.updatePreferences { preferences in
            for url in panel.urls { preferences.addExtraFolder(url.path) }
        }
    }
}

/// One app on the Auto Quit list: its icon and name, its own minutes, and a remove button.
private struct AppsAutoQuitRow: View {
    let rule: AppsAutoQuitRule
    let defaultMinutes: Int

    var body: some View {
        HStack(spacing: 8) {
            if let entry = AppsFeature.catalog.entry(bundleID: rule.bundleID) {
                LauncherIconView(icon: .file(entry.url), side: 18)
                Text(entry.name)
            } else {
                Image(systemName: "app.dashed").frame(width: 18)
                Text(rule.name).foregroundStyle(.secondary)
                    .help("Not installed in the folders the launcher searches")
            }
            Spacer()
            Picker("", selection: Binding(
                get: { rule.minutes ?? 0 },
                set: { minutes in
                    AppsFeature.updatePreferences {
                        $0.setAutoQuit(bundleID: rule.bundleID, name: rule.name, minutes: minutes == 0 ? nil : minutes)
                    }
                })) {
                Text("Default (\(AppsAutoQuit.durationText(defaultMinutes)))").tag(0)
                Divider()
                ForEach(AppsAutoQuit.durations, id: \.self) { minutes in
                    Text(AppsAutoQuit.durationText(minutes)).tag(minutes)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                AppsFeature.updatePreferences { $0.removeAutoQuit(bundleID: rule.bundleID) }
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove from Auto Quit")
        }
    }
}

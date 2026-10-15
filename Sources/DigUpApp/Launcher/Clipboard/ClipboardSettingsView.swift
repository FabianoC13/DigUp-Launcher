import AppKit
import DigUpKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Launcher → Clipboard History: how long it keeps copies, pausing, apps it ignores, clearing it.
struct ClipboardSettingsView: View {
    @Bindable var store: ClipboardStore

    var body: some View {
        Picker("Keep history for", selection: $store.settings.retention) {
            ForEach(ClipboardRetention.allCases, id: \.self) { retention in
                Text(retention.title).tag(retention)
            }
        }
        Toggle(isOn: $store.settings.numberKeys) {
            Text("Paste recent copies with fn+1 … fn+9")
            Text("Anywhere, without opening DigUp: fn+1 pastes your last copy, fn+2 the one before. Needs Accessibility.")
        }
        Toggle(isOn: $store.settings.paused) {
            Text("Pause recording")
            Text("While paused, nothing you copy is added. Pinned and earlier entries stay.")
        }
        LabeledContent {
            Button("Clear History…", role: .destructive, action: clear)
                .disabled(store.entries.allSatisfy(\.pinned))
        } label: {
            Text("History")
            Text(summary)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Don't record copies from")
            Text("Copies marked secret (passwords from password managers) are never recorded, whatever the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(store.settings.ignoredApps) { app in
                HStack(spacing: 8) {
                    Image(nsImage: Self.icon(of: app.bundleID))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(app.name)
                    Text(app.bundleID).font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        store.settings.ignoredApps.removeAll { $0.bundleID == app.bundleID }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Record copies from \(app.name) again")
                }
            }
            Button("Add App…", action: addApps)
        }
    }

    private var summary: String {
        let count = store.entries.count
        let pinned = store.entries.filter(\.pinned).count
        var text = count == 1 ? "1 entry" : "\(count) entries"
        if pinned > 0 { text += ", \(pinned) pinned" }
        return text
    }

    private static func icon(of bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    private func clear() {
        let count = store.entries.filter { !$0.pinned }.count
        let alert = NSAlert()
        alert.messageText = "Delete \(count == 1 ? "1 entry" : "\(count) entries") from Clipboard History?"
        alert.informativeText = "Pinned entries stay. This can't be undone."
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteAllUnpinned()
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.title = "Don't Record Copies From"
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !store.settings.ignoredApps.contains(where: { $0.bundleID == bundleID }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            store.settings.ignoredApps.append(.init(bundleID: bundleID, name: name))
        }
    }
}

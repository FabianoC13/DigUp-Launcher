import AppKit
import DigUpKit
import SwiftUI

/// The items that have an alias or a hotkey, each removable.
struct QuicklinksPersonalSettings: View {
    let launcher: Launcher
    let store: QuicklinksStore

    /// Item id → its title and icon, looked up from the providers (they're async).
    @State private var items: [String: (title: String, icon: LauncherIcon)] = [:]

    var body: some View {
        // Read so the list follows changes made from the panel (the launcher's usage isn't observable).
        let revision = store.personalizationRevision
        let usage = launcher.usage
        let ids = Set(usage.aliases.keys).union(usage.hotkeys.keys).sorted { a, b in
            (items[a]?.title ?? a).localizedStandardCompare(items[b]?.title ?? b) == .orderedAscending
        }
        Group {
            if ids.isEmpty {
                Text("No aliases or hotkeys yet.").foregroundStyle(.secondary)
            }
            ForEach(ids, id: \.self) { id in
                row(id, alias: usage.aliases[id], hotkey: usage.hotkeys[id].flatMap { KeyCombo($0) })
            }
            if !usage.favorites.isEmpty {
                HStack {
                    Text(usage.favorites.count == 1 ? "1 favorite" : "\(usage.favorites.count) favorites")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Favorites") { clearFavorites() }
                }
            }
        }
        .task(id: revision) { await loadItems(Set(ids)) }
    }

    private func row(_ id: String, alias: String?, hotkey: KeyCombo?) -> some View {
        HStack(spacing: 10) {
            if let icon = items[id]?.icon {
                LauncherIconView(icon: icon, side: 18)
            } else {
                Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary).frame(width: 18)
            }
            Text(items[id]?.title ?? id).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let alias {
                tag(alias, monospaced: true)
                Button { remove(alias: id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Remove the alias “\(alias)”")
            }
            if let hotkey {
                if store.failedHotkeys.contains(id) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("Another app has \(hotkey.display), so this hotkey doesn't work")
                }
                tag(hotkey.display, monospaced: false)
                Button { remove(hotkey: id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Remove the hotkey \(hotkey.display)")
            }
        }
    }

    private func tag(_ text: String, monospaced: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
    }

    private func remove(alias id: String) {
        launcher.personalize { QuicklinksPersonalization.setAlias(nil, for: id, in: &$0) }
    }

    private func remove(hotkey id: String) {
        launcher.personalize { QuicklinksPersonalization.setHotkey(nil, for: id, in: &$0) }
    }

    private func clearFavorites() {
        guard QuicklinksAlert.confirm("Clear all favorites?",
                                      message: "They stop showing first in the launcher; nothing else changes.",
                                      button: "Clear Favorites", destructive: true) else { return }
        launcher.personalize { $0.favorites = [] }
    }

    private func loadItems(_ ids: Set<String>) async {
        var found = items.filter { ids.contains($0.key) }
        for id in ids where found[id] == nil {
            if let item = await launcher.item(id: id) { found[id] = (item.title, item.icon) }
            if Task.isCancelled { return }
        }
        items = found
    }
}

/// The Hyper Key's switches and what it's doing.
struct QuicklinksHyperKeySettings: View {
    let store: QuicklinksStore

    var body: some View {
        let settings = store.settings
        Toggle("Use Caps Lock as the Hyper Key",
               isOn: Binding(get: { settings.hyperKeyEnabled }, set: { QuicklinksHyperKey.shared.setEnabled($0) }))
        if settings.hyperKeyEnabled {
            Toggle("Include ⇧", isOn: Binding(get: { settings.hyperIncludesShift }, set: { on in
                store.updateSettings { $0.hyperIncludesShift = on }
                QuicklinksHyperKey.shared.settingsChanged()
            }))
            .help("Off: Caps Lock is ⌃⌥⌘, and ⇧ can be added to it")
            Picker("Caps Lock pressed alone", selection: Binding(get: { settings.hyperQuickPress }, set: { press in
                store.updateSettings { $0.hyperQuickPress = press }
                QuicklinksHyperKey.shared.settingsChanged()
            })) {
                Text("Does nothing").tag(QuicklinksSettings.QuickPress.nothing)
                Text("Escape").tag(QuicklinksSettings.QuickPress.escape)
            }
            status
        }
    }

    @ViewBuilder private var status: some View {
        switch store.hyperKeyStatus {
        case .on:
            Label("On: hold Caps Lock and press a key. Caps Lock comes back when it's off or DigUp quits.",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .off:
            EmptyView()
        case .needsAccessibility:
            HStack {
                Label("DigUp needs Accessibility to add the keys", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                Spacer()
                Button("Open Accessibility Settings") { Accessibility.openSettings() }
            }
        case .failed(let problem):
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(.red)
        }
    }
}

/// Deeplinks (what they look like, which run without asking) and Export / Import.
struct QuicklinksBackupSettings: View {
    let launcher: Launcher
    let store: QuicklinksStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Every item's actions have Copy Deeplink (⌥⌘C): a digup://run link that runs it from a browser, "
                 + "a script or Shortcuts. Also digup://search?q=…, digup://ai?q=… and digup://quicklink/<name>?q=….")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        let trusted = store.settings.trustedDeeplinks
        if !trusted.isEmpty {
            HStack {
                Text(trusted.count == 1 ? "1 item runs from links without asking"
                     : "\(trusted.count) items run from links without asking")
                Spacer()
                Button("Ask Again") { store.updateSettings { $0.trustedDeeplinks = [] } }
            }
        }
        HStack {
            Text("Quicklinks, favorites, aliases, hotkeys and snippets")
            Spacer()
            Button("Import…") {
                Task {
                    if let outcome = await QuicklinksBackupFiles.importFile(launcher: launcher, store: store) {
                        QuicklinksAlert.inform(outcome.title, detail: outcome.detail)
                    }
                }
            }
            Button("Export…") {
                Task {
                    if let outcome = await QuicklinksBackupFiles.export(launcher: launcher, store: store) {
                        QuicklinksAlert.inform(outcome.title, detail: outcome.detail)
                    }
                }
            }
        }
    }
}

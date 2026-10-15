import AppKit
import DigUpKit
import SwiftUI

/// Settings → Launcher → Quicklinks & Shortcuts: the quicklinks, the fallback commands, aliases and hotkeys, the
/// Hyper Key, deeplinks, and import/export.
struct QuicklinksSettingsView: View {
    let launcher: Launcher
    let store: QuicklinksStore

    var body: some View {
        QuicklinksSettingsHeading("Quicklinks",
                                  note: "Type a quicklink's name or keyword, a space and what to search for: “g cats”.")
        QuicklinksListSettings(launcher: launcher, store: store)
        QuicklinksSettingsHeading("Fallback Commands",
                                  note: "Offered below every search, with what you typed. Quicklinks that take one "
                                      + "value can be fallbacks too.")
        QuicklinksFallbackSettings(store: store)
        QuicklinksSettingsHeading("Aliases & Hotkeys",
                                  note: "Set them from any item's actions (⌘K): Set Alias…, Set Hotkey….")
        QuicklinksPersonalSettings(launcher: launcher, store: store)
        QuicklinksSettingsHeading("Hyper Key",
                                  note: "Caps Lock becomes ⌃⌥⇧⌘ held together, for hotkeys that no app uses.")
        QuicklinksHyperKeySettings(store: store)
        QuicklinksSettingsHeading("Deeplinks & Backup", note: nil)
        QuicklinksBackupSettings(launcher: launcher, store: store)
    }
}

/// A part's title in the section, with a line about it.
struct QuicklinksSettingsHeading: View {
    let title: String
    let note: String?

    init(_ title: String, note: String?) {
        self.title = title
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }
}

/// Every quicklink, with Edit and Delete, and Add.
private struct QuicklinksListSettings: View {
    let launcher: Launcher
    let store: QuicklinksStore

    var body: some View {
        if store.links.isEmpty {
            Text("No quicklinks.").foregroundStyle(.secondary)
        }
        ForEach(store.links) { record in
            HStack(spacing: 10) {
                LauncherIconView(icon: store.icon(for: record), side: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(record.name).lineLimit(1)
                        if let keyword = record.keyword {
                            Text(keyword)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                    }
                    Text(QuicklinkTemplate.display(record.link))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Edit…") { QuicklinksEditor.show(record, store: store, launcher: launcher) { _ in } }
                Button {
                    delete(record)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete “\(record.name)”")
            }
        }
        HStack {
            Button("Add Quicklink…") { QuicklinksEditor.show(nil, store: store, launcher: launcher) { _ in } }
            Spacer()
            if !store.links.contains(where: { $0.name == "Google Search" }) {
                Button("Add the Default Quicklinks") { addDefaults() }
                    .help("Google Search, YouTube, GitHub, Wikipedia, Google Maps and Google Translate")
            }
        }
    }

    private func delete(_ record: QuicklinkRecord) {
        guard QuicklinksAlert.confirm("Delete “\(record.name)”?", message: "Its alias, hotkey and favorite go with it.",
                                      button: "Delete", destructive: true) else { return }
        store.delete(record)
        launcher.personalize { $0.forget("ql:\(record.id)") }
        log("quicklinks: deleted one")
    }

    /// The first-run quicklinks back, those that aren't here (by name and link).
    private func addDefaults() {
        var links = store.links
        var summary = QuicklinksBackup.Summary()
        QuicklinksBackup(quicklinks: QuicklinkRecord.defaults()).mergeQuicklinks(into: &links, summary: &summary)
        store.replaceAll(links)
    }
}

/// The fallback commands: on or off, and their order.
private struct QuicklinksFallbackSettings: View {
    let store: QuicklinksStore

    var body: some View {
        let entries = store.fallbackEntries
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { entry.enabled }, set: { store.setFallback(entry.id, enabled: $0) })) {
                    Text(title(of: entry.id))
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button { store.moveFallback(at: index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help("Move up")
                Button { store.moveFallback(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == entries.count - 1)
                    .help("Move down")
            }
        }
    }

    private func title(of id: String) -> String {
        if let title = QuicklinksFallbacks.title(of: id) { return title }
        let key = String(id.dropFirst(QuicklinksFallbacks.quicklinkPrefix.count))
        return store.record(id: key).map { "Quicklink: \($0.name)" } ?? id
    }
}

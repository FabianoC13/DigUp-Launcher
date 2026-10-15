import AppKit
import Carbon.HIToolbox
import DigUpKit
import SwiftUI

/// The items' own hotkeys (`LauncherUsage.hotkeys`, set with Set Hotkey…): one `GlobalHotkey` each, which runs the item
/// as ↩ would. Registered at launch and again whenever favorites, aliases or hotkeys change; all off while a shortcut
/// recorder listens, so the keys reach it.
final class QuicklinksHotkeys {
    static let shared = QuicklinksHotkeys()

    private var registered: [String: GlobalHotkey] = [:]
    private weak var launcher: Launcher?
    private var store: QuicklinksStore?
    /// How many recorders are listening.
    private var listeners = 0

    private init() {}

    func start(launcher: Launcher, store: QuicklinksStore) {
        self.launcher = launcher
        self.store = store
        launcher.onPersonalizationChanged.append { [weak self, weak store] in
            self?.sync()
            store?.personalizationChanged()
        }
        sync()
        if !launcher.usage.hotkeys.isEmpty { log("quicklinks: \(registered.count) item hotkeys") }
    }

    /// A shortcut recorder started (true) or stopped listening.
    func listening(_ on: Bool) {
        listeners = max(0, listeners + (on ? 1 : -1))
        sync()
    }

    /// Registers what's in the launcher's usage and drops what isn't any more.
    func sync() {
        guard let launcher else { return }
        let wanted = listeners > 0 ? [:] : launcher.usage.hotkeys
        for (id, hotkey) in registered where wanted[id] != hotkey.combo.spec {
            registered[id] = nil
        }
        guard listeners == 0 else { return }
        var failed = Set<String>()
        for (id, spec) in wanted.sorted(by: { $0.key < $1.key }) where registered[id] == nil {
            guard let combo = KeyCombo(spec),
                  let hotkey = GlobalHotkey(combo, action: { [weak self] in self?.fire(id) }) else {
                failed.insert(id)
                log("quicklinks: hotkey \(KeyCombo(spec)?.display ?? spec) can't be registered (another app has it?)")
                continue
            }
            registered[id] = hotkey
        }
        if store?.failedHotkeys != failed { store?.failedHotkeys = failed }
    }

    private func fire(_ id: String) {
        guard let launcher else { return }
        Task { await launcher.run(itemID: id) }
    }

    /// Why `combo` can't be `id`'s hotkey, or nil when it can. `owners` names the items that have hotkeys.
    func problem(with combo: KeyCombo, for id: String, app: AppController, owners: [String: String]) -> String? {
        if let conflict = combo.systemConflict { return conflict + " (System Settings → Keyboard → Keyboard Shortcuts)" }
        if app.hotkeys.combo == combo { return "\(combo.display) opens the launcher" }
        let key = combo.caps.last ?? ""
        let isFunctionKey = key.count > 1 && key.hasPrefix("F")
        if combo.carbonModifiers == UInt32(cmdKey), !isFunctionKey {
            return "\(combo.display) is an app shortcut everywhere: add ⌥, ⌃ or ⇧"
        }
        if let launcher, let owner = QuicklinksPersonalization.hotkeyOwner(combo.spec, in: launcher.usage, except: id) {
            return "“\(owners[owner] ?? owner)” has \(combo.display)"
        }
        // Another app's hotkey: try it (ours are off while the recorder listens, so only others can be in the way).
        guard GlobalHotkey(combo, action: {}) != nil else { return "Another app is using \(combo.display)" }
        return nil
    }
}

/// Set Hotkey…: a small window with the shortcut recorder, for one item.
enum QuicklinksHotkeyRecorder {
    static func show(for item: LauncherItem, launcher: Launcher, app: AppController, done: @escaping () -> Void) {
        QuicklinksWindow.show(key: "hotkey:\(item.id)", title: "Hotkey",
                              content: { close in
                                  QuicklinksHotkeyView(item: item, launcher: launcher, app: app, close: close)
                              },
                              onClose: done)
    }
}

private struct QuicklinksHotkeyView: View {
    let item: LauncherItem
    let launcher: Launcher
    let app: AppController
    let close: () -> Void

    @State private var combo: KeyCombo?
    /// Titles of the items that have hotkeys, to say which one already has a combination.
    @State private var owners: [String: String] = [:]
    @State private var isListening = false

    init(item: LauncherItem, launcher: Launcher, app: AppController, close: @escaping () -> Void) {
        self.item = item
        self.launcher = launcher
        self.app = app
        self.close = close
        _combo = State(initialValue: launcher.usage.hotkeys[item.id].flatMap { KeyCombo($0) })
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                LauncherIconView(icon: item.icon, side: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("Runs it from any app, as ↩ would in the launcher.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ShortcutRecorder(combo: combo, apply: apply, listening: listening)
            HStack {
                if combo != nil {
                    Button("Remove Hotkey", role: .destructive) {
                        launcher.personalize { QuicklinksPersonalization.setHotkey(nil, for: item.id, in: &$0) }
                        combo = nil
                        log("quicklinks: removed a hotkey")
                    }
                }
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isListening)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task { await loadOwners() }
        .onDisappear { if isListening { listening(false) } }
    }

    private func apply(_ new: KeyCombo) -> String? {
        if let problem = QuicklinksHotkeys.shared.problem(with: new, for: item.id, app: app, owners: owners) {
            return problem
        }
        launcher.personalize { QuicklinksPersonalization.setHotkey(new.spec, for: item.id, in: &$0) }
        combo = new
        log("quicklinks: set a hotkey \(new.display)")
        return nil
    }

    /// While the recorder listens, no hotkey fires: the launcher's own and every item's step aside.
    private func listening(_ on: Bool) {
        guard on != isListening else { return }
        isListening = on
        QuicklinksHotkeys.shared.listening(on)
        app.hotkeyRecording(on)
    }

    private func loadOwners() async {
        var titles: [String: String] = [:]
        for id in launcher.usage.hotkeys.keys where id != item.id {
            titles[id] = await launcher.item(id: id)?.title
        }
        owners = titles
    }
}

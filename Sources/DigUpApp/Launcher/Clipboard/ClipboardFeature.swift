import AppKit
import DigUpKit
import SwiftUI

/// Clipboard History: everything you copy, searchable, pinnable, pasted back with ↩.
enum ClipboardFeature: LauncherFeature {
    private static var watcher: ClipboardWatcher?
    private static var pruneTimer: Timer?

    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [ClipboardCommandsProvider()]
    }

    /// Loads the history, then starts watching the pasteboard; expired entries go once an hour.
    static func start(_ launcher: Launcher) {
        let store = ClipboardStore.shared
        store.onChange.append { [weak launcher] in
            // An open Clipboard History shows a new copy (or a deleted entry) right away.
            guard let panel = launcher?.panel, panel.isVisible, panel.mode is ClipboardHistoryMode else { return }
            panel.refresh()
        }
        Task {
            await store.load()
            let watcher = ClipboardWatcher(store: store)
            watcher.start()
            Self.watcher = watcher
            ClipboardNumberKeys.shared.update()
        }
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardStore.shared.prune() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { ClipboardStore.shared.saveNow() }
        }
    }

    static var settingsTitle: String? { "Clipboard History" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(ClipboardSettingsView(store: ClipboardStore.shared))
    }
}

/// The root search's "Clipboard History" command (history entries themselves are only in its own list).
final class ClipboardCommandsProvider: LauncherProvider {
    let id = "clip"
    static let historyID = "clip:history"

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty,
              let score = query.match("Clipboard History", keywords: ["clipboard", "history", "paste", "copied", "pasteboard"])
        else { return [] }
        return [historyItem(score: score)]
    }

    func item(id: String) async -> LauncherItem? {
        id == Self.historyID ? historyItem(score: 0.5) : nil
    }

    private func historyItem(score: Double) -> LauncherItem {
        let store = ClipboardStore.shared
        let count = store.entries.count
        return LauncherItem(
            id: Self.historyID, title: "Clipboard History",
            subtitle: store.settings.paused ? "Recording paused" : "\(count) \(count == 1 ? "entry" : "entries")",
            icon: .symbol("doc.on.clipboard"), accessory: "Command", score: score,
            actions: [
                LauncherAction(id: "open", title: "Open Clipboard History", symbol: "doc.on.clipboard",
                               keepsPanelOpen: true) { context in
                    context.push(ClipboardHistoryMode())
                },
                LauncherAction(id: "pause", title: store.settings.paused ? "Resume Recording" : "Pause Recording",
                               symbol: store.settings.paused ? "play.circle" : "pause.circle",
                               keepsPanelOpen: true) { context in
                    ClipboardStore.shared.settings.paused.toggle()
                    context.flash(ClipboardStore.shared.settings.paused ? "Clipboard recording paused"
                                  : "Clipboard recording resumed")
                    context.refresh()
                },
                LauncherAction(id: "settings", title: "Clipboard History Settings…", symbol: "gearshape",
                               shortcut: LauncherShortcut(",", .command)) { context in
                    context.app.settingsWindow.show(.launcher)
                },
            ],
            detail: .summary,
            metadata: [("Entries", count.formatted()), ("Keeps", store.settings.retention.title)])
    }
}

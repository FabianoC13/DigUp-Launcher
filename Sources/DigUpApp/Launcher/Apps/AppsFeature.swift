import AppKit
import DigUpKit
import SwiftUI

/// Applications, System Settings panes, running apps and files by name (Spotlight's index).
///
/// Four providers: "app" (every app on this Mac, plus Quit Applications, Show Running Applications and Manage Auto
/// Quit), "pane" (each pane of System Settings, and the permission lists of Privacy & Security), and "file" (files and
/// folders whose names match, and typed paths like "~/Documents/"). The catalogs fill in `start`, off the main thread.
enum AppsFeature: LauncherFeature {
    /// Every app on this Mac, kept fresh.
    static let catalog = AppsCatalog()
    /// The panes of System Settings on this Mac.
    static let panes = AppsPaneCatalog()
    /// Settings → Launcher → Applications.
    static let preferences = AppsPreferencesStore()
    static let autoQuit = AppsAutoQuitEngine()

    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [AppsProvider(), AppsPanesProvider(), AppsFilesProvider()]
    }

    static func start(_ launcher: Launcher) {
        catalog.start(extraFolders: preferences.value.extraFolders)
        panes.load()
        autoQuit.apply(preferences.value)
    }

    static var settingsTitle: String? { "Applications" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(AppsSettingsView(store: preferences))
    }

    /// Changes the Applications settings, saves them, and lets the catalog and Auto Quit catch up.
    static func updatePreferences(_ change: (inout AppsPreferences) -> Void) {
        let old = preferences.value
        preferences.update(change)
        let new = preferences.value
        if new.extraFolders != old.extraFolders { catalog.setExtraFolders(new.extraFolders) }
        if new.autoQuitEnabled != old.autoQuitEnabled || new.autoQuitApps != old.autoQuitApps
            || new.autoQuitMinutes != old.autoQuitMinutes {
            autoQuit.apply(new)
        }
    }

    /// Where the feature keeps its files.
    static var directory: URL { Launcher.directory.appendingPathComponent("Apps", isDirectory: true) }

    /// Says something went wrong: in the panel's footer when it's up, else in an alert (the panel hides before most
    /// actions run).
    static func report(_ title: String, message: String = "", context: LauncherContext) {
        log("apps: \(title) \(message)")
        if context.isPanelVisible {
            context.flash(message.isEmpty ? title : "\(title) \(message)")
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        bringAppToFront()
        alert.runModal()
    }

    /// Asks a running app to quit and waits (up to `timeout`) until it has; false when it's still running (it asked
    /// about unsaved work, or refused).
    static func quitAndWait(_ app: NSRunningApplication, timeout: Duration = .seconds(10)) async -> Bool {
        guard app.terminate() else { return app.isTerminated }
        let deadline = ContinuousClock.now + timeout
        while !app.isTerminated, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return app.isTerminated
    }
}

/// The Applications settings, saved as JSON in the feature's folder.
@Observable
final class AppsPreferencesStore {
    private(set) var value: AppsPreferences

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private static var file: URL { AppsFeature.directory.appendingPathComponent("preferences.json") }

    init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode(AppsPreferences.self, from: data) {
            value = saved
        } else {
            value = AppsPreferences()
        }
    }

    /// Changes and saves (only when something changed).
    func update(_ change: (inout AppsPreferences) -> Void) {
        var changed = value
        change(&changed)
        guard changed != value else { return }
        value = changed
        save()
    }

    private func save() {
        saveTask?.cancel()
        let value = self.value
        let file = Self.file
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Task.detached {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try encoder.encode(value).write(to: file, options: .atomic)
                } catch {
                    log("apps: couldn't save preferences: \(error.localizedDescription)")
                }
            }.value
        }
    }
}

/// Finder through Apple events (Show Info): the first time, macOS asks whether DigUp may control Finder.
nonisolated enum AppsAppleScript {
    /// The script's error, nil when it ran.
    struct Failure: Error, Sendable {
        let number: Int
        let message: String

        /// macOS said no (Privacy & Security → Automation).
        var isNotPermitted: Bool { number == -1743 }
    }

    /// Runs `source` off the main thread: the first run waits for the permission dialog.
    static func run(_ source: String) async -> Failure? {
        await Task.detached(priority: .userInitiated) { () -> Failure? in
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                return Failure(number: 0, message: "The script couldn't be read.")
            }
            script.executeAndReturnError(&error)
            guard let error else { return nil }
            return Failure(number: error[NSAppleScript.errorNumber] as? Int ?? 0,
                           message: error[NSAppleScript.errorMessage] as? String ?? "Unknown error")
        }.value
    }

    /// A path as an AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Finder's Get Info window for a file, folder or app.
    @MainActor static func showInfo(_ url: URL, context: LauncherContext) async {
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file \(quoted(url.path)) as alias)
        end tell
        """
        guard let failure = await run(source) else { return }
        if failure.isNotPermitted {
            if context.confirm("DigUp isn't allowed to control Finder",
                               message: "Show Info asks Finder to open its Get Info window. Allow DigUp under "
                                   + "Finder in Privacy & Security → Automation.",
                               button: "Open Privacy Settings") {
                NSWorkspace.shared.open(URL(string: AppsSettingsPanes.url(for: AppsSettingsPanes.privacyPane,
                                                                          anchor: "Privacy_Automation"))!)
            }
        } else {
            AppsFeature.report("Couldn't show info.", message: failure.message, context: context)
        }
    }
}

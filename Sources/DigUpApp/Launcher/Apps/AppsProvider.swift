import AppKit
import DigUpKit

/// "app": every app on this Mac ("app:/Applications/Safari.app"), and the commands for running apps and Auto Quit
/// ("app:quit-mode", "app:running", "app:auto-quit").
final class AppsProvider: LauncherProvider {
    let id = "app"

    /// More than this many matching apps is noise (one letter typed matches half of them).
    static let limit = 40

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        let running = AppsRunning.byPath()
        var matches: [(entry: AppsEntry, score: Double)] = []
        for entry in AppsFeature.catalog.entries {
            if let score = query.match(entry.name, keywords: entry.keywords) { matches.append((entry, score)) }
        }
        matches.sort { $0.score > $1.score }
        var items = matches.prefix(Self.limit).map { match in
            AppsItems.app(match.entry, running: running[match.entry.path], score: match.score)
        }
        for command in AppsCommand.allCases {
            if let score = query.match(command.title, keywords: command.keywords) {
                items.append(command.item(score: score))
            }
        }
        return items
    }

    func item(id: String) async -> LauncherItem? {
        let key = String(id.dropFirst(self.id.count + 1))
        if let command = AppsCommand(rawValue: key) { return command.item(score: 0.5) }
        guard key.hasPrefix("/") else { return nil }
        let running = AppsRunning.byPath()
        if let entry = AppsFeature.catalog.entry(path: key) {
            return AppsItems.app(entry, running: running[key], score: 0.5)
        }
        // A favorite asked for before the first scan is done, or an app outside the scanned folders.
        guard FileManager.default.fileExists(atPath: key) else { return nil }
        let entry = await Task.detached(priority: .userInitiated) {
            AppsScanner.read(key, source: .installed)
        }.value
        return entry.map { AppsItems.app($0, running: running[key], score: 0.5) }
    }
}

/// The apps that are running now, by bundle path.
enum AppsRunning {
    static func byPath() -> [String: NSRunningApplication] {
        var result: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let path = app.bundleURL?.path else { continue }
            // A regular app wins over a helper that shares its bundle (rare, but then the app is the one shown).
            if let current = result[path], current.activationPolicy == .regular { continue }
            result[path] = app
        }
        return result
    }

    /// Regular apps (with a Dock icon) other than DigUp, by name.
    static func regularApps() -> [NSRunningApplication] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    /// Brings an app forward, unhiding it first if it was hidden.
    static func activate(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        app.activate()
    }

    /// Asks the app to quit, says so if it didn't (it may be asking about unsaved work).
    static func quit(_ app: NSRunningApplication, context: LauncherContext) async {
        let name = app.localizedName ?? "The app"
        if await AppsFeature.quitAndWait(app) {
            if context.isPanelVisible { context.flash("Quit \(name)") }
        } else if !app.isTerminated {
            AppsFeature.report("\(name) didn't quit.", message: "It may be asking about unsaved changes.",
                               context: context)
        }
    }

    /// Kills the app at once, after asking.
    static func forceQuit(_ app: NSRunningApplication, context: LauncherContext) async {
        let name = app.localizedName ?? "this app"
        guard context.confirm("Force quit \(name)?", message: "Unsaved changes in \(name) will be lost.",
                              button: "Force Quit", destructive: true) else { return }
        if !app.forceTerminate() {
            AppsFeature.report("Couldn't force quit \(name).", context: context)
        }
    }

    /// Quits the app and opens it again once it's gone.
    static func restart(_ app: NSRunningApplication, context: LauncherContext) async {
        guard let url = app.bundleURL else { return }
        let name = app.localizedName ?? "The app"
        guard await AppsFeature.quitAndWait(app) else {
            AppsFeature.report("\(name) didn't quit, so it wasn't restarted.",
                               message: "It may be asking about unsaved changes.", context: context)
            return
        }
        await AppsItems.open(url, context: context)
    }
}

/// The commands the "app" provider offers besides the apps.
enum AppsCommand: String, CaseIterable {
    case quitMode = "quit-mode"
    case running = "running"
    case autoQuit = "auto-quit"

    var title: String {
        switch self {
        case .quitMode: "Quit Applications"
        case .running: "Show Running Applications"
        case .autoQuit: "Manage Auto Quit"
        }
    }

    var keywords: [String] {
        switch self {
        case .quitMode: ["close apps", "kill apps", "running apps", "force quit"]
        case .running: ["running apps", "open apps", "switch apps", "processes"]
        case .autoQuit: ["auto quit", "quit automatically", "inactive apps"]
        }
    }

    var subtitle: String {
        switch self {
        case .quitMode: "Quit, hide or force quit running apps"
        case .running: "Switch to, hide or quit running apps"
        case .autoQuit: "Apps that quit after a while in the background"
        }
    }

    func item(score: Double) -> LauncherItem {
        let command = self
        let symbol = switch self {
        case .quitMode: "xmark.app"
        case .running: "square.stack.3d.up"
        case .autoQuit: "timer"
        }
        let action: LauncherAction = switch self {
        case .quitMode, .running:
            LauncherAction(id: "open", title: "Open Command", symbol: "arrow.right", keepsPanelOpen: true) { context in
                context.push(AppsRunningMode(quitting: command == .quitMode))
            }
        case .autoQuit:
            LauncherAction(id: "open", title: "Open Auto Quit Settings", symbol: "gearshape") { context in
                context.app.settingsWindow.show(.launcher)
            }
        }
        return LauncherItem(id: "app:" + rawValue, title: title, subtitle: subtitle, icon: .symbol(symbol),
                            accessory: "Command", score: score, actions: [action])
    }
}

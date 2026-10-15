import AppKit
import DigUpKit
import SwiftUI

/// Quit Applications / Show Running Applications: the apps with a Dock icon that are running now. In Quit
/// Applications ↩ quits the selected app and the list stays up for the next; in Show Running Applications ↩ switches
/// to it. Both offer hide, quit, force quit and restart, and quitting every app listed.
final class AppsRunningMode: LauncherMode {
    let quitting: Bool

    init(quitting: Bool) {
        self.quitting = quitting
    }

    var title: String { quitting ? "Quit Applications" : "Running Applications" }
    var placeholder: String { "Filter running apps…" }
    var icon: LauncherIcon { .symbol(quitting ? "xmark.app" : "square.stack.3d.up") }
    var statusHint: String? {
        let count = AppsRunning.regularApps().count
        return count == 1 ? "1 app running" : "\(count) apps running"
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let apps = AppsRunning.regularApps()
        var items: [LauncherItem] = []
        for app in apps {
            let name = app.localizedName ?? app.bundleURL.map { AppsScanner.displayName($0.path) } ?? "Unknown"
            let score: Double
            if query.isEmpty {
                score = 0.5
            } else if let match = query.match(name, keywords: [app.bundleIdentifier].compactMap { $0 }) {
                score = match
            } else {
                continue
            }
            items.append(item(app, name: name, score: score))
        }
        if query.isEmpty, apps.count > 1 {
            items.append(quitAllItem(apps))
        }
        return items
    }

    private func item(_ app: NSRunningApplication, name: String, score: Double) -> LauncherItem {
        let switchTo = LauncherAction(id: "switch", title: "Switch to \(name)", symbol: "macwindow") { _ in
            AppsRunning.activate(app)
        }
        let quit = LauncherAction(id: "quit", title: "Quit \(name)", symbol: "xmark.circle",
                                  shortcut: LauncherShortcut("q", [.command, .option]),
                                  keepsPanelOpen: true) { context in
            await AppsRunning.quit(app, context: context)
            context.refresh()
        }
        let hide = app.isHidden
            ? LauncherAction(id: "unhide", title: "Unhide", symbol: "eye",
                             shortcut: LauncherShortcut("h", [.command, .option]), keepsPanelOpen: true) { context in
                app.unhide()
                context.refresh()
            }
            : LauncherAction(id: "hide", title: "Hide", symbol: "eye.slash",
                             shortcut: LauncherShortcut("h", [.command, .option]), keepsPanelOpen: true) { context in
                if !app.hide() { context.flash("\(name) didn't hide") }
                context.refresh()
            }
        let forceQuit = LauncherAction(id: "force-quit", title: "Force Quit \(name)",
                                       symbol: "exclamationmark.octagon",
                                       shortcut: LauncherShortcut("q", [.command, .option, .shift]),
                                       style: .destructive, keepsPanelOpen: true) { context in
            await AppsRunning.forceQuit(app, context: context)
            try? await Task.sleep(for: .milliseconds(300))
            context.refresh()
        }
        let restart = LauncherAction(id: "restart", title: "Restart \(name)", symbol: "arrow.clockwise",
                                     shortcut: LauncherShortcut("r", [.command, .option])) { context in
            await AppsRunning.restart(app, context: context)
        }
        let actions = quitting ? [quit, switchTo, hide, restart, forceQuit] : [switchTo, hide, quit, restart, forceQuit]

        var metadata: [(label: String, value: String)] = []
        if let bundleID = app.bundleIdentifier { metadata.append(("Bundle ID", bundleID)) }
        metadata.append(("Process ID", String(app.processIdentifier)))
        if let launched = app.launchDate { metadata.append(("Launched", AppsFormat.date(launched))) }
        metadata.append(("State", app.isActive ? "In front" : app.isHidden ? "Hidden" : "In the background"))
        if let path = app.bundleURL?.path {
            metadata.append(("Location", AppsFormat.tildePath((path as NSString).deletingLastPathComponent,
                                                             home: NSHomeDirectory())))
        }
        let icon: LauncherIcon = app.bundleURL.map { .file($0) } ?? app.icon.map { .image($0) } ?? .symbol("app")
        return LauncherItem(
            id: "app:pid:\(app.processIdentifier)", title: name, subtitle: app.isHidden ? "Hidden" : nil, icon: icon,
            accessory: app.isHidden ? "Hidden" : "Running", section: .named("Running Applications", order: 0),
            score: score, actions: actions, metadata: metadata, tracksUsage: false)
    }

    /// Quit every app listed, after asking.
    private func quitAllItem(_ apps: [NSRunningApplication]) -> LauncherItem {
        LauncherItem(
            id: "app:quit-all-listed", title: "Quit All \(apps.count) Applications",
            subtitle: "Apps with unsaved changes ask first", icon: .symbol("xmark.circle", .red),
            accessory: "Command", section: .named("All", order: 1), score: 0.1,
            actions: [
                LauncherAction(id: "quit-all", title: "Quit All Applications", symbol: "xmark.circle",
                               style: .destructive, keepsPanelOpen: true) { context in
                    let names = apps.compactMap(\.localizedName).joined(separator: ", ")
                    guard context.confirm("Quit \(apps.count) applications?", message: names, button: "Quit All",
                                          destructive: true) else { return }
                    // Asked all at once, then given ten seconds together to finish.
                    for app in apps where !app.isTerminated { app.terminate() }
                    let deadline = ContinuousClock.now + .seconds(10)
                    while apps.contains(where: { !$0.isTerminated }), ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    let left = apps.filter { !$0.isTerminated }.count
                    context.flash(left == 0 ? "Quit all applications"
                        : "\(left) didn't quit (unsaved changes?)")
                    context.refresh()
                },
            ],
            tracksUsage: false)
    }
}

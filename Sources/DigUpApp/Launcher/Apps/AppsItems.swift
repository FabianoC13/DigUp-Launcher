import AppKit
import DigUpKit

/// Launcher rows for apps, with the actions Raycast offers on them.
enum AppsItems {
    /// A running app ranks a little higher: it's likely the one meant.
    static let runningBoost = 0.05

    static func app(_ entry: AppsEntry, running: NSRunningApplication?, score: Double) -> LauncherItem {
        let url = entry.url
        let isRunning = running.map { !$0.isTerminated } ?? false
        var actions: [LauncherAction] = [
            LauncherAction(id: "open", title: "Open Application", symbol: "arrow.up.forward.app") { context in
                await open(url, context: context)
            },
            LauncherAction(id: "reveal", title: "Show in Finder", symbol: "folder", shortcut: .commandReturn) { _ in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            LauncherAction(id: "info", title: "Show Info in Finder", symbol: "info.circle",
                           shortcut: LauncherShortcut("i", .command)) { context in
                await AppsAppleScript.showInfo(url, context: context)
            },
            LauncherAction(id: "contents", title: "Show Package Contents", symbol: "shippingbox",
                           shortcut: LauncherShortcut("o", [.command, .option])) { context in
                let contents = url.appendingPathComponent("Contents", isDirectory: true)
                if !NSWorkspace.shared.open(contents) {
                    AppsFeature.report("Couldn't open the package contents.", context: context)
                }
            },
            LauncherAction(id: "copy-path", title: "Copy Path", symbol: "doc.on.clipboard", shortcut: .copyShift) {
                context in
                context.copy(url.path)
            },
            LauncherAction(id: "copy-name", title: "Copy Name", symbol: "textformat") { context in
                context.copy(entry.name)
            },
        ]
        if let bundleID = entry.bundleID {
            actions.append(LauncherAction(id: "copy-bundle-id", title: "Copy Bundle Identifier", symbol: "number",
                                          shortcut: LauncherShortcut("c", [.command, .option])) { context in
                context.copy(bundleID)
            })
        }
        if let running, isRunning {
            actions += runningActions(running)
        }
        if let bundleID = entry.bundleID, !AppsAutoQuit.neverQuit.contains(bundleID) {
            actions.append(autoQuitAction(bundleID: bundleID, name: entry.name))
        }
        if !entry.isSystem {
            actions.append(LauncherAction(id: "trash", title: "Move to Trash", symbol: "trash",
                                          shortcut: .deleteItem, style: .destructive) { context in
                await moveToTrash(entry, context: context)
            })
        }

        let home = NSHomeDirectory()
        let folder = (entry.path as NSString).deletingLastPathComponent
        var metadata: [(label: String, value: String)] = []
        if let version = entry.version { metadata.append(("Version", version)) }
        if let bundleID = entry.bundleID { metadata.append(("Bundle ID", bundleID)) }
        metadata.append(("Location", AppsFormat.tildePath(folder, home: home)))
        metadata.append(("Status", isRunning ? (running?.isHidden == true ? "Running (hidden)" : "Running")
            : "Not running"))
        if AppsFeature.preferences.value.autoQuitEnabled, let bundleID = entry.bundleID,
           let rule = AppsFeature.preferences.value.autoQuitRule(for: bundleID) {
            let minutes = rule.minutes ?? AppsFeature.preferences.value.autoQuitMinutes
            metadata.append(("Auto Quit", "After \(AppsAutoQuit.durationText(minutes)) in the background"))
        }
        // Apps outside the usual folders say where they are, so two copies can be told apart.
        let usual = ["/Applications", "/System/Applications", home + "/Applications"]
        let subtitle = usual.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") })
            ? nil : AppsFormat.tildePath(folder, home: home)
        return LauncherItem(
            id: "app:" + entry.path, title: entry.name, subtitle: subtitle, icon: .file(url),
            accessory: isRunning ? "Running" : "Application",
            score: min(1, score + (isRunning ? runningBoost : 0)), actions: actions, metadata: metadata)
    }

    /// Hide, Quit, Force Quit and Restart for a running app.
    static func runningActions(_ app: NSRunningApplication) -> [LauncherAction] {
        [
            app.isHidden
                ? LauncherAction(id: "unhide", title: "Unhide Application", symbol: "eye",
                                 shortcut: LauncherShortcut("h", [.command, .option])) { _ in
                    AppsRunning.activate(app)
                }
                : LauncherAction(id: "hide", title: "Hide Application", symbol: "eye.slash",
                                 shortcut: LauncherShortcut("h", [.command, .option])) { context in
                    if !app.hide() { AppsFeature.report("\(app.localizedName ?? "The app") didn't hide.",
                                                        context: context) }
                },
            LauncherAction(id: "quit", title: "Quit Application", symbol: "xmark.circle",
                           shortcut: LauncherShortcut("q", [.command, .option])) { context in
                await AppsRunning.quit(app, context: context)
            },
            LauncherAction(id: "restart", title: "Restart Application", symbol: "arrow.clockwise",
                           shortcut: LauncherShortcut("r", [.command, .option])) { context in
                await AppsRunning.restart(app, context: context)
            },
            LauncherAction(id: "force-quit", title: "Force Quit Application", symbol: "exclamationmark.octagon",
                           shortcut: LauncherShortcut("q", [.command, .option, .shift]), style: .destructive) {
                context in
                await AppsRunning.forceQuit(app, context: context)
            },
        ]
    }

    /// Turns Auto Quit on or off for an app (turning it on also turns Auto Quit itself on).
    static func autoQuitAction(bundleID: String, name: String) -> LauncherAction {
        let preferences = AppsFeature.preferences.value
        let isOn = preferences.autoQuitEnabled && preferences.autoQuitRule(for: bundleID) != nil
        return LauncherAction(id: "auto-quit", title: isOn ? "Disable Auto Quit" : "Enable Auto Quit",
                              symbol: isOn ? "timer.circle.fill" : "timer", keepsPanelOpen: true) { context in
            AppsFeature.updatePreferences { preferences in
                if isOn {
                    preferences.removeAutoQuit(bundleID: bundleID)
                } else {
                    preferences.setAutoQuit(bundleID: bundleID, name: name, minutes: nil)
                    preferences.autoQuitEnabled = true
                }
            }
            let minutes = AppsFeature.preferences.value.autoQuitMinutes
            context.flash(isOn ? "Auto Quit off for \(name)"
                : "\(name) quits after \(AppsAutoQuit.durationText(minutes)) in the background")
            context.refresh()
        }
    }

    /// Opens the app, or brings it forward (unhidden) if it's running.
    static func open(_ url: URL, context: LauncherContext) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            if app.isHidden { app.unhide() }
        } catch {
            AppsFeature.report("Couldn't open \(AppsScanner.displayName(url.path)).",
                               message: error.localizedDescription, context: context)
        }
    }

    /// Moves an app to the Trash after asking, quitting it first if it's running.
    static func moveToTrash(_ entry: AppsEntry, context: LauncherContext) async {
        guard context.confirm("Move \(entry.name) to the Trash?",
                              message: "\(AppsFormat.tildePath(entry.path, home: NSHomeDirectory())) goes to the "
                                  + "Trash. Its settings and support files stay.",
                              button: "Move to Trash", destructive: true) else { return }
        if let running = AppsRunning.byPath()[entry.path], !running.isTerminated {
            guard await AppsFeature.quitAndWait(running) else {
                AppsFeature.report("\(entry.name) didn't quit, so it wasn't moved to the Trash.", context: context)
                return
            }
        }
        do {
            try await NSWorkspace.shared.recycle([entry.url])
            AppsFeature.catalog.scheduleRescan(after: .zero)
        } catch {
            AppsFeature.report("Couldn't move \(entry.name) to the Trash.", message: error.localizedDescription,
                               context: context)
        }
    }
}

/// How the feature writes paths, sizes and dates.
enum AppsFormat {
    /// "~/Documents/Report.pdf" for a path in the home folder.
    nonisolated static func tildePath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

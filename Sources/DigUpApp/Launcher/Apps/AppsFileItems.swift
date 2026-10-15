import AppKit
import DigUpKit

/// Launcher rows for files and folders, with File Search's actions.
enum AppsFileItems {
    /// A file or folder as a row. `browsing`: it's listed under a typed path, so ↩ on a folder lists its contents.
    static func item(_ hit: AppsFileHit, score: Double, section: LauncherSection = .files,
                     browsing: Bool = false) -> LauncherItem {
        let url = hit.url
        let home = NSHomeDirectory()
        let folder = (hit.path as NSString).deletingLastPathComponent
        // An app opens itself.
        let isApp = url.pathExtension.lowercased() == "app"
        let appName = isApp ? nil : NSWorkspace.shared.urlForApplication(toOpen: url)
            .map { AppsScanner.displayName($0.path) }

        let open = LauncherAction(id: "open", title: hit.isFolder ? "Open in Finder" : isApp ? "Open Application"
            : appName.map { "Open with \($0)" } ?? "Open", symbol: "arrow.up.forward.square") { context in
            if !NSWorkspace.shared.open(url) {
                AppsFeature.report("Couldn't open \(hit.name).", context: context)
            }
        }
        let reveal = LauncherAction(id: "reveal", title: "Show in Finder", symbol: "folder",
                                    shortcut: .commandReturn) { _ in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        var actions: [LauncherAction]
        if browsing, hit.isFolder {
            let typed = AppsFileSearchRules.typedPath(hit.path, home: home)
            actions = [
                LauncherAction(id: "enter", title: "Show Contents", symbol: "arrow.right.circle",
                               keepsPanelOpen: true) { context in
                    context.query = typed
                },
                LauncherAction(id: "open", title: "Open in Finder", symbol: "folder", shortcut: .commandReturn) {
                    context in
                    if !NSWorkspace.shared.open(url) { AppsFeature.report("Couldn't open \(hit.name).",
                                                                          context: context) }
                },
            ]
        } else {
            actions = [open, reveal]
        }
        if !hit.isFolder, !isApp {
            actions.append(LauncherAction(id: "open-with", title: "Open With…", symbol: "square.grid.2x2",
                                          shortcut: LauncherShortcut("o", [.command, .shift]),
                                          keepsPanelOpen: true) { context in
                context.push(AppsOpenWithMode(url: url))
            })
        }
        actions += [
            LauncherAction(id: "info", title: "Show Info in Finder", symbol: "info.circle",
                           shortcut: LauncherShortcut("i", .command)) { context in
                await AppsAppleScript.showInfo(url, context: context)
            },
            LauncherAction(id: "copy-file", title: "Copy File", symbol: "doc.on.doc", shortcut: .copy) { context in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if pasteboard.writeObjects([url as NSURL]), context.isPanelVisible {
                    context.flash("Copied \(hit.name)")
                }
            },
            LauncherAction(id: "copy-path", title: "Copy Path", symbol: "doc.on.clipboard", shortcut: .copyShift) {
                context in
                context.copy(hit.path)
            },
            LauncherAction(id: "copy-name", title: "Copy Name", symbol: "textformat",
                           shortcut: LauncherShortcut("c", [.command, .option])) { context in
                context.copy(hit.name)
            },
        ]
        if hit.isFolder {
            actions.append(LauncherAction(id: "terminal", title: "Open in Terminal", symbol: "terminal",
                                          shortcut: LauncherShortcut("t", [.command, .shift])) { context in
                await openInTerminal(url, context: context)
            })
            if !browsing {
                let typed = AppsFileSearchRules.typedPath(hit.path, home: home)
                actions.append(LauncherAction(id: "enter", title: "Show Contents", symbol: "arrow.right.circle",
                                              keepsPanelOpen: true) { context in
                    context.popToRoot()
                    context.query = typed
                })
            }
        }
        actions += [
            LauncherAction(id: "duplicate", title: "Save as Duplicate", symbol: "plus.square.on.square",
                           shortcut: LauncherShortcut("d", .command), keepsPanelOpen: true) { context in
                await duplicate(url, context: context)
            },
            LauncherAction(id: "trash", title: "Move to Trash", symbol: "trash", shortcut: .deleteItem,
                           style: .destructive, keepsPanelOpen: true) { context in
                await moveToTrash(url, context: context)
            },
        ]

        var metadata: [(label: String, value: String)] = []
        if let kind = hit.kind { metadata.append(("Kind", kind)) }
        if let size = hit.size, !hit.isFolder { metadata.append(("Size", AppsFormat.size(size))) }
        if let modified = hit.modified { metadata.append(("Modified", AppsFormat.date(modified))) }
        if let used = hit.lastUsed { metadata.append(("Last Opened", AppsFormat.date(used))) }
        if let appName, !hit.isFolder { metadata.append(("Opens With", appName)) }
        metadata.append(("Where", AppsFormat.tildePath(folder, home: home)))
        return LauncherItem(
            id: "file:" + hit.path, title: hit.name, subtitle: AppsFormat.tildePath(folder, home: home),
            icon: .file(url), accessory: hit.isFolder ? "Folder" : nil, section: section, score: score,
            actions: actions, detail: .file(url), metadata: metadata, tracksUsage: true)
    }

    /// A new Terminal window in the folder.
    static func openInTerminal(_ folder: URL, context: LauncherContext) async {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            AppsFeature.report("Terminal isn't installed.", context: context)
            return
        }
        do {
            _ = try await NSWorkspace.shared.open([folder], withApplicationAt: terminal,
                                                  configuration: NSWorkspace.OpenConfiguration())
        } catch {
            AppsFeature.report("Couldn't open Terminal.", message: error.localizedDescription, context: context)
        }
    }

    /// A copy next to the original, named the way Finder would ("Report copy.pdf").
    static func duplicate(_ url: URL, context: LauncherContext) async {
        let folder = url.deletingLastPathComponent()
        let name = AppsFileSearchRules.duplicateName(for: url.lastPathComponent) { candidate in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
        }
        let target = folder.appendingPathComponent(name)
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.copyItem(at: url, to: target)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure {
            AppsFeature.report("Couldn't duplicate \(url.lastPathComponent).", message: failure, context: context)
        } else {
            context.flash("Saved \(name)")
            context.refresh()
        }
    }

    /// Moves a file or folder to the Trash after asking.
    static func moveToTrash(_ url: URL, context: LauncherContext) async {
        let name = url.lastPathComponent
        guard context.confirm("Move “\(name)” to the Trash?",
                              message: AppsFormat.tildePath(url.path, home: NSHomeDirectory()),
                              button: "Move to Trash", destructive: true) else { return }
        do {
            try await NSWorkspace.shared.recycle([url])
            context.flash("Moved \(name) to the Trash")
            context.refresh()
        } catch {
            AppsFeature.report("Couldn't move \(name) to the Trash.", message: error.localizedDescription,
                               context: context)
        }
    }
}

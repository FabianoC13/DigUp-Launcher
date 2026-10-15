import AppKit
import DigUpKit
import SwiftUI

/// Script Commands: your scripts, with Raycast-style metadata, run from the launcher.
enum ScriptsFeature: LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [ScriptsProvider(library: .shared)]
    }

    static func start(_ launcher: Launcher) {
        ScriptsLibrary.shared.start()
    }

    static var settingsTitle: String? { "Script Commands" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(ScriptsSettingsView(library: .shared))
    }
}

/// Root search: the scripts (what's typed after a title is its arguments: "weather berlin") and the commands that
/// manage them.
final class ScriptsProvider: LauncherProvider {
    let id = "script"
    private let library: ScriptsLibrary

    init(library: ScriptsLibrary) {
        self.library = library
    }

    private enum Command: String, CaseIterable {
        case folder, create, reload

        var title: String {
            switch self {
            case .folder: "Open Script Commands Folder"
            case .create: "Create Script Command"
            case .reload: "Reload Script Commands"
            }
        }

        var keywords: [String] {
            switch self {
            case .folder: ["scripts", "script directory"]
            case .create: ["new script", "add script"]
            case .reload: ["refresh scripts", "rescan scripts"]
            }
        }

        var symbol: String {
            switch self {
            case .folder: "folder"
            case .create: "plus.square.on.square"
            case .reload: "arrow.clockwise"
            }
        }
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        library.rescanIfStale()
        var items: [LauncherItem] = []
        for script in library.scripts {
            let keywords = [script.metadata.packageName].compactMap { $0 }
            guard let match = ScriptCommandLine.match(query.text, title: script.title, keywords: keywords,
                                                      takesArguments: !script.metadata.arguments.isEmpty) else {
                continue
            }
            var item = makeItem(script, typed: match.rest)
            item.score = match.score
            items.append(item)
        }
        for command in Command.allCases {
            guard let score = query.match(command.title, keywords: command.keywords) else { continue }
            var item = makeItem(command)
            item.score = score
            items.append(item)
        }
        return items
    }

    func item(id: String) async -> LauncherItem? {
        let key = String(id.dropFirst(ScriptsLibrary.itemPrefix.count))
        if let command = Command(rawValue: key) { return makeItem(command) }
        if library.scripts.isEmpty { library.rescan() }
        return library.script(id: id).map { makeItem($0, typed: "") }
    }

    // MARK: Items

    private func makeItem(_ script: ScriptCommand, typed: String) -> LauncherItem {
        let metadata = script.metadata
        var subtitle: String?
        if !typed.isEmpty {
            subtitle = "With “\(typed)”"
        } else if let inline = library.inlineOutputs[script.id] {
            subtitle = inline.text
        } else if !metadata.arguments.isEmpty {
            subtitle = "Type after the title: " + metadata.arguments
                .map { $0.optional ? "\($0.placeholder) (optional)" : $0.placeholder }
                .joined(separator: ", ")
        } else {
            subtitle = metadata.description ?? metadata.packageName
        }
        var details: [(label: String, value: String)] = []
        if let package = metadata.packageName { details.append(("Package", package)) }
        if let description = metadata.description { details.append(("Description", description)) }
        details.append(("Output", Self.describe(metadata.mode)))
        if !metadata.arguments.isEmpty {
            details.append(("Arguments", metadata.arguments.map(\.placeholder).joined(separator: ", ")))
        }
        details.append(("File", tildePath(script.url.path)))
        if let author = metadata.author { details.append(("Author", author)) }
        if let inline = library.inlineOutputs[script.id] {
            details.append(("Last output", inline.text))
        }
        let asksFirst = ScriptsRunner.needsArgumentMode(script, typed: typed)
        var actions = [
            LauncherAction(id: "run", title: "Run Script", symbol: "play",
                           keepsPanelOpen: asksFirst || metadata.mode != .silent) { context in
                await ScriptsRunner.start(script, typed: typed, context: context)
            },
            LauncherAction(id: "edit", title: "Edit Script", symbol: "pencil") { _ in
                ProductivityEditor.open(script.url)
            },
            LauncherAction(id: "reveal", title: "Show in Finder", symbol: "folder",
                           shortcut: LauncherShortcut("f", [.command, .shift])) { _ in
                NSWorkspace.shared.activateFileViewerSelecting([script.url])
            },
            LauncherAction(id: "copy-path", title: "Copy Path", symbol: "link", shortcut: .copyShift,
                           keepsPanelOpen: true) { context in
                context.copy(script.url.path)
            },
        ]
        if let inline = library.inlineOutputs[script.id] {
            actions.append(LauncherAction(id: "copy-output", title: "Copy Last Output", symbol: "doc.on.doc",
                                          shortcut: LauncherShortcut("c", [.command, .option]),
                                          keepsPanelOpen: true) { context in
                context.copy(inline.text)
            })
        }
        return LauncherItem(id: script.id, title: script.title, subtitle: subtitle, icon: library.icon(for: script),
                            accessory: "Script Command", actions: actions, metadata: details)
    }

    private func makeItem(_ command: Command) -> LauncherItem {
        let library = self.library
        let action: LauncherAction
        switch command {
        case .folder:
            action = LauncherAction(id: "open", title: "Open Folder", symbol: "folder") { _ in
                NSWorkspace.shared.open(ScriptsLibrary.folder)
            }
        case .create:
            action = LauncherAction(id: "create", title: "Create Script Command", symbol: "plus") { context in
                guard let title = context.prompt("New Script Command",
                                                 message: "Its title, as the launcher will show it. DigUp writes a "
                                                     + "Bash script with the metadata filled in and opens it.",
                                                 button: "Create")?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return }
                guard let url = library.create(title: title) else {
                    ProductivityHUD.show("Couldn't create the script", symbol: "exclamationmark.triangle")
                    return
                }
                ProductivityEditor.open(url)
                ProductivityHUD.show("Created \(url.lastPathComponent)", symbol: "checkmark.circle")
            }
        case .reload:
            action = LauncherAction(id: "reload", title: "Reload", symbol: "arrow.clockwise",
                                    keepsPanelOpen: true) { context in
                library.rescan()
                // The scan takes a moment; say what it found.
                for _ in 0..<50 where library.scanning { try? await Task.sleep(for: .milliseconds(100)) }
                let count = library.scripts.count
                context.flash(count == 1 ? "1 script command" : "\(count) script commands")
                context.refresh()
            }
        }
        let subtitle: String = switch command {
        case .folder: tildePath(ScriptsLibrary.folder.path)
        case .create: "A new script with Raycast's metadata, in the scripts folder"
        case .reload: library.scripts.count == 1 ? "1 script command" : "\(library.scripts.count) script commands"
        }
        return LauncherItem(id: ScriptsLibrary.itemPrefix + command.rawValue, title: command.title, subtitle: subtitle,
                            icon: .symbol(command.symbol), accessory: "Command", actions: [action])
    }

    static func describe(_ mode: ScriptCommandMetadata.Mode) -> String {
        switch mode {
        case .fullOutput: "Full output"
        case .compact: "Last line"
        case .silent: "Last line, panel closes"
        case .inline: "Last line, kept in the list"
        }
    }
}

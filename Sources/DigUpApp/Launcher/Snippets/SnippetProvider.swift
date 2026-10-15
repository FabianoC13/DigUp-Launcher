import AppKit
import DigUpKit
import SwiftUI

/// The root search's snippets: the commands (Search Snippets, Create Snippet, Import, Export) and every snippet whose
/// name, keyword or text matches what's typed.
final class SnippetProvider: LauncherProvider {
    let id = "snip"
    static let searchID = "snip:search"
    static let createID = "snip:create"
    static let importID = "snip:import"
    static let exportID = "snip:export"

    /// At most this many snippets in the root results; Search Snippets shows them all.
    private static let rootLimit = 6

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        var items = Self.commands.compactMap { command -> LauncherItem? in
            guard let score = query.match(command.title, keywords: command.keywords) else { return nil }
            return Self.commandItem(command, score: score)
        }
        let store = SnippetStore.shared
        let preview = SnippetItems.previewValues()
        let matches = store.snippets
            .compactMap { snippet in SnippetLibrary.score(snippet, query: query.raw).map { (snippet, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.rootLimit)
        for (snippet, score) in matches {
            items.append(SnippetItems.item(snippet, score: score * 0.9, preview: preview))
        }
        return items
    }

    func item(id: String) async -> LauncherItem? {
        if let command = Self.commands.first(where: { $0.id == id }) { return Self.commandItem(command, score: 0.5) }
        let key = String(id.dropFirst(self.id.count + 1))
        guard id.hasPrefix(self.id + ":"), let snippet = SnippetStore.shared.snippet(key) else { return nil }
        return SnippetItems.item(snippet, score: 0.5, preview: SnippetItems.previewValues())
    }

    // MARK: Commands

    private struct Command {
        var id: String
        var title: String
        var subtitle: String
        var symbol: String
        var keywords: [String]
        var keepsPanelOpen = false
        var run: @MainActor (LauncherContext) async -> Void
    }

    private static let commands: [Command] = [
        Command(id: searchID, title: "Search Snippets", subtitle: "Paste, copy and edit your snippets",
                symbol: "text.quote", keywords: ["snippets", "text expansion", "templates", "paste"],
                keepsPanelOpen: true) { context in
            context.push(SnippetSearchMode())
        },
        Command(id: createID, title: "Create Snippet", subtitle: "Save text to paste or expand with a keyword",
                symbol: "plus.square.on.square", keywords: ["new snippet", "add snippet", "text expansion"]) { _ in
            SnippetEditor.shared.open(nil)
        },
        Command(id: importID, title: "Import Snippets…", subtitle: "From a JSON file (Raycast's export works too)",
                symbol: "square.and.arrow.down", keywords: ["snippets", "import", "raycast"]) { _ in
            if let message = SnippetStore.shared.importFromFile() { SnippetStore.tell(message) }
        },
        Command(id: exportID, title: "Export Snippets…", subtitle: "Save every snippet as a JSON file",
                symbol: "square.and.arrow.up", keywords: ["snippets", "export", "backup"]) { _ in
            if let message = SnippetStore.shared.exportToFile() { SnippetStore.tell(message) }
        },
    ]

    private static func commandItem(_ command: Command, score: Double) -> LauncherItem {
        let count = SnippetStore.shared.snippets.count
        return LauncherItem(
            id: command.id, title: command.title, subtitle: command.subtitle, icon: .symbol(command.symbol),
            accessory: "Command", score: score,
            actions: [
                LauncherAction(id: "run", title: command.title, symbol: command.symbol,
                               keepsPanelOpen: command.keepsPanelOpen, run: command.run),
                LauncherAction(id: "settings", title: "Snippets Settings…", symbol: "gearshape",
                               shortcut: LauncherShortcut(",", .command)) { context in
                    context.app.settingsWindow.show(.launcher)
                },
            ],
            metadata: [("Snippets", count.formatted())])
    }
}

/// A snippet as a row, with its actions. The root search and Search Snippets share these.
enum SnippetItems {
    /// What the preview reads: the clipboard as it is now (read once), and a stand-in for each {argument}.
    static func previewValues() -> SnippetPlaceholderValues {
        let clipboard = NSPasteboard.general.string(forType: .string)
        return SnippetPlaceholderValues(clipboard: { $0 == 0 ? clipboard : nil },
                                        snippet: { SnippetStore.shared.text(named: $0) })
    }

    static func item(_ snippet: Snippet, score: Double, section: LauncherSection = .results,
                     preview values: SnippetPlaceholderValues) -> LauncherItem {
        var subtitle = snippet.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if subtitle.count > 80 { subtitle = String(subtitle.prefix(79)) + "…" }
        var metadata: [(label: String, value: String)] = []
        if let keyword = snippet.keyword { metadata.append(("Keyword", keyword)) }
        metadata.append(("Characters", snippet.text.count.formatted()))
        metadata.append(("Modified", snippet.modified.formatted(.relative(presentation: .named))))
        return LauncherItem(
            id: "snip:\(snippet.id)", title: snippet.name, subtitle: subtitle,
            icon: .symbol(snippet.pinned ? "pin.fill" : "text.quote"),
            accessory: snippet.keyword ?? "Snippet", section: section, score: score,
            actions: actions(for: snippet), detail: .text(preview(snippet, values: values)), metadata: metadata)
    }

    /// The snippet as it would paste now: placeholders filled, {argument}s shown by name or default.
    static func preview(_ snippet: Snippet, values: SnippetPlaceholderValues) -> String {
        guard SnippetPlaceholders.hasPlaceholders(snippet.text) else { return snippet.text }
        var values = values
        let arguments = SnippetPlaceholders.arguments(in: snippet.text) { SnippetStore.shared.text(named: $0) }
        values.arguments = Dictionary(arguments.map { ($0.key, $0.defaultValue ?? "[\($0.name)]") },
                                      uniquingKeysWith: { first, _ in first })
        return SnippetPlaceholders.expand(snippet.text, values: values).text
    }

    static func actions(for snippet: Snippet) -> [LauncherAction] {
        let id = snippet.id
        return [
            LauncherAction(id: "paste", title: "Paste Snippet", symbol: "doc.on.clipboard") { context in
                guard let snippet = SnippetStore.shared.snippet(id) else { return }
                let pasted = await SnippetPaster.paste(snippet, into: context.previousApp)
                if !pasted, !Accessibility.isTrusted() {
                    context.flash("Copied “\(snippet.name)”: allow DigUp in Accessibility to paste")
                }
            },
            LauncherAction(id: "copy", title: "Copy Snippet", symbol: "doc.on.doc",
                           shortcut: .commandReturn) { context in
                guard let snippet = SnippetStore.shared.snippet(id) else { return }
                var answers: [String: String] = [:]
                let arguments = SnippetPlaceholders.arguments(in: snippet.text) { SnippetStore.shared.text(named: $0) }
                if !arguments.isEmpty {
                    guard let given = SnippetPaster.askArguments(arguments, snippet: snippet.name) else { return }
                    answers = given
                }
                let text = SnippetPlaceholders.expand(snippet.text, values: SnippetPaster.values(arguments: answers)).text
                context.copy(text, flash: "Copied “\(snippet.name)”")
            },
            LauncherAction(id: "edit", title: "Edit Snippet", symbol: "pencil",
                           shortcut: LauncherShortcut("e", .command)) { _ in
                SnippetEditor.shared.open(SnippetStore.shared.snippet(id))
            },
            LauncherAction(id: "pin", title: snippet.pinned ? "Unpin Snippet" : "Pin Snippet",
                           symbol: snippet.pinned ? "pin.slash" : "pin",
                           shortcut: LauncherShortcut("p", [.command, .shift]), keepsPanelOpen: true) { context in
                SnippetStore.shared.togglePin(id)
                context.refresh()
            },
            LauncherAction(id: "duplicate", title: "Duplicate Snippet", symbol: "plus.square.on.square",
                           shortcut: LauncherShortcut("d", .command), keepsPanelOpen: true) { context in
                guard let copy = SnippetStore.shared.duplicate(id) else { return }
                context.flash("Added “\(copy.name)”")
                context.refresh()
            },
            LauncherAction(id: "delete", title: "Delete Snippet", symbol: "trash", shortcut: .deleteItem,
                           style: .destructive, keepsPanelOpen: true) { context in
                guard let snippet = SnippetStore.shared.snippet(id),
                      context.confirm("Delete “\(snippet.name)”?",
                                      message: (snippet.keyword.map { "Typing “\($0)” won't expand anymore. " } ?? "")
                                          + "This can't be undone.",
                                      button: "Delete", destructive: true) else { return }
                SnippetStore.shared.delete(id)
                context.flash("Deleted “\(snippet.name)”")
                context.refresh()
            },
            LauncherAction(id: "create", title: "Create Snippet", symbol: "plus",
                           shortcut: LauncherShortcut("n", .command)) { _ in
                SnippetEditor.shared.open(nil)
            },
        ]
    }
}

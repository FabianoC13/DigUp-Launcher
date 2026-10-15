import AppKit
import DigUpKit
import SwiftUI

/// Notes: a floating note window and a searchable list of notes.
enum NotesFeature: LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [NotesProvider()]
    }

    static func start(_ launcher: Launcher) {
        NotesStore.shared.start()
        NotesWindowController.shared.launcher = launcher
    }
}

/// Root search: Create Note, Search Notes, Open Last Note, and the notes whose title or text has what's typed.
final class NotesProvider: LauncherProvider {
    let id = "note"
    static let prefix = "note:"

    private enum Command: String, CaseIterable {
        case create, search, last

        var title: String {
            switch self {
            case .create: "Create Note"
            case .search: "Search Notes"
            case .last: "Open Last Note"
            }
        }

        var keywords: [String] {
            switch self {
            case .create: ["new note", "write", "jot"]
            case .search: ["notes", "browse notes", "find note"]
            case .last: ["notes", "floating note", "recent note"]
            }
        }

        var symbol: String {
            switch self {
            case .create: "square.and.pencil"
            case .search: "magnifyingglass"
            case .last: "note.text"
            }
        }
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        let store = NotesStore.shared
        store.reloadIfStale(after: 30)
        var items: [LauncherItem] = []
        for command in Command.allCases {
            guard let score = query.match(command.title, keywords: command.keywords) else { continue }
            var item = makeItem(command)
            item.score = score
            items.append(item)
        }
        for note in store.notes where !note.isBlank {
            guard let (score, snippet) = Self.match(note, query: query, contentMinimum: 3) else { continue }
            var item = Self.makeItem(note, snippet: snippet)
            item.score = score * 0.9   // a command of the same name stays above a note
            items.append(item)
            if items.count >= 12 { break }
        }
        return items
    }

    func item(id: String) async -> LauncherItem? {
        let key = String(id.dropFirst(Self.prefix.count))
        if let command = Command(rawValue: key) { return makeItem(command) }
        return NotesStore.shared.note(key).map { Self.makeItem($0, snippet: nil) }
    }

    private func makeItem(_ command: Command) -> LauncherItem {
        let store = NotesStore.shared
        let action: LauncherAction
        var subtitle: String?
        switch command {
        case .create:
            subtitle = "A floating note that saves itself as you type"
            action = LauncherAction(id: "create", title: "Create Note", symbol: "square.and.pencil") { _ in
                NotesWindowController.shared.openNew()
            }
        case .search:
            let count = store.notes.filter { !$0.isBlank }.count
            subtitle = count == 1 ? "1 note" : "\(count) notes"
            action = LauncherAction(id: "search", title: "Search Notes", symbol: "magnifyingglass",
                                    keepsPanelOpen: true) { context in
                context.push(NotesSearchMode())
            }
        case .last:
            subtitle = store.lastOpened.map { "“\($0.title)”" } ?? "No notes yet: starts a new one"
            action = LauncherAction(id: "last", title: "Open Last Note", symbol: "note.text") { _ in
                NotesWindowController.shared.toggle()
            }
        }
        return LauncherItem(id: Self.prefix + command.rawValue, title: command.title, subtitle: subtitle,
                            icon: .symbol(command.symbol), accessory: "Command", actions: [action])
    }

    // MARK: Notes

    /// How well a note matches: by its title, else (for queries of `contentMinimum` characters or more) by its text,
    /// with the words around the match.
    static func match(_ note: NoteFile, query: LauncherQuery, contentMinimum: Int) -> (Double, String?)? {
        if let score = query.match(note.title) { return (score, nil) }
        guard query.text.count >= contentMinimum,
              let snippet = NotesText.snippet(of: note.text, matching: query.text) else { return nil }
        return (0.45, snippet)
    }

    static func makeItem(_ note: NoteFile, snippet: String?, section: LauncherSection = .results) -> LauncherItem {
        let store = NotesStore.shared
        let id = note.id
        let excerpt = NotesText.excerpt(of: note.text)
        var actions = [
            LauncherAction(id: "open", title: "Open Note", symbol: "macwindow") { _ in
                NotesWindowController.shared.open(id)
            },
            LauncherAction(id: "copy", title: "Copy Text", symbol: "doc.on.doc", shortcut: .commandReturn,
                           keepsPanelOpen: true) { context in
                guard let note = store.note(id) else { return }
                context.copy(NotesText.plainText(fromMarkdown: note.text))
            },
            LauncherAction(id: "copy-markdown", title: "Copy as Markdown", symbol: "number", shortcut: .copyShift,
                           keepsPanelOpen: true) { context in
                guard let note = store.note(id) else { return }
                context.copy(note.text, flash: "Copied as Markdown")
            },
            LauncherAction(id: "paste", title: "Paste Text", symbol: "doc.on.clipboard",
                           shortcut: LauncherShortcut("v", [.command, .shift])) { context in
                guard let note = store.note(id) else { return }
                context.paste(NotesText.plainText(fromMarkdown: note.text))
            },
            LauncherAction(id: "pin", title: store.isPinned(id) ? "Unpin Note" : "Pin Note",
                           symbol: store.isPinned(id) ? "pin.slash" : "pin",
                           shortcut: LauncherShortcut("p", [.command, .shift]), keepsPanelOpen: true) { context in
                store.togglePin(id)
                context.flash(store.isPinned(id) ? "Pinned" : "Unpinned")
                context.refresh()
            },
            LauncherAction(id: "export", title: "Export…", symbol: "square.and.arrow.up",
                           shortcut: LauncherShortcut("e", [.command, .shift])) { _ in
                guard let note = store.note(id) else { return }
                store.export(note)
            },
        ]
        actions.append(LauncherAction(id: "delete", title: "Delete Note", symbol: "trash", shortcut: .deleteItem,
                                      style: .destructive, keepsPanelOpen: true) { context in
            guard let note = store.note(id) else { return }
            guard context.confirm("Delete “\(note.title)”?", message: "The note goes to the Trash.", button: "Delete",
                                  destructive: true) else { return }
            store.delete(id)
            NotesWindowController.shared.editor.drop(id)
            context.flash("Moved to the Trash")
            context.refresh()
        })
        let words = NotesEditing.wordCount(note.text)
        let metadata: [(label: String, value: String)] = [
            ("Modified", note.modified.formatted(date: .abbreviated, time: .shortened)),
            ("Created", note.created.formatted(date: .abbreviated, time: .shortened)),
            ("Words", "\(words)"),
        ]
        return LauncherItem(id: prefix + id, title: note.title, subtitle: snippet ?? (excerpt.isEmpty ? nil : excerpt),
                            icon: .symbol(store.isPinned(id) ? "pin.fill" : "note.text", .yellow), accessory: "Note",
                            section: section, actions: actions, detail: .markdown(note.text), metadata: metadata)
    }
}

/// Search Notes: every note, pinned ones first, then most recently changed; ↩ opens one in the note window.
final class NotesSearchMode: LauncherMode {
    let title = "Search Notes"
    let placeholder = "Search notes…"
    let icon = LauncherIcon.symbol("note.text", .yellow)
    var keysHint: String? { "↩ Open  ⌘↩ Copy  ⌃X Delete" }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let store = NotesStore.shared
        store.reloadIfStale()
        let notes = store.notes.filter { !$0.isBlank }
        var items: [LauncherItem] = []
        let pinnedSection = LauncherSection.named("Pinned", order: 0)
        let notesSection = LauncherSection.named("Notes", order: 1)
        for (index, note) in notes.enumerated() {
            let pinned = store.isPinned(note.id)
            if query.isEmpty {
                var item = NotesProvider.makeItem(note, snippet: nil, section: pinned ? pinnedSection : notesSection)
                item.score = 1 - Double(index) / Double(max(notes.count, 1)) * 0.5
                items.append(item)
            } else if let (score, snippet) = NotesProvider.match(note, query: query, contentMinimum: 1) {
                var item = NotesProvider.makeItem(note, snippet: snippet, section: pinned ? pinnedSection : notesSection)
                item.score = score
                items.append(item)
            }
        }
        if !query.isEmpty {
            let text = query.text
            items.append(LauncherItem(
                id: NotesProvider.prefix + "create", title: "Create Note “\(text)”", subtitle: "A new note with this as its title",
                icon: .symbol("square.and.pencil"), accessory: "Command", section: .named("New", order: 2), score: 0.01,
                actions: [LauncherAction(id: "create", title: "Create Note", symbol: "square.and.pencil") { _ in
                    NotesWindowController.shared.openNew(text: text + "\n\n")
                }],
                tracksUsage: false))
        } else if notes.isEmpty {
            items.append(LauncherItem(
                id: NotesProvider.prefix + "create", title: "Create Note", subtitle: "No notes yet",
                icon: .symbol("square.and.pencil"), accessory: "Command", actions: [
                    LauncherAction(id: "create", title: "Create Note", symbol: "square.and.pencil") { _ in
                        NotesWindowController.shared.openNew()
                    },
                ], tracksUsage: false))
        }
        return items
    }
}

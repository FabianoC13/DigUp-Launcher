import AppKit
import DigUpKit
import SwiftUI

/// Root search's quicklinks ("ql:<id>"): a quicklink by its name or keyword, with what follows as its argument ("google
/// cats", "g cats", or an alias and a space), and the feature's commands ("ql:@create"…).
final class QuicklinksProvider: LauncherProvider {
    let id = "ql"
    private unowned let launcher: Launcher
    private let store: QuicklinksStore

    init(launcher: Launcher, store: QuicklinksStore) {
        self.launcher = launcher
        self.store = store
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        let builder = QuicklinksItems(launcher: launcher, store: store)
        var items: [LauncherItem] = []
        for record in store.links {
            let template = store.template(for: record)
            var found = QuicklinkMatcher.match(query.text, name: record.name, keyword: record.keyword,
                                               takesArgument: template.takesArgument)
                .map { (score: $0.score, argument: $0.argument) }
            // Its alias, a space, and the argument: the alias picks it whatever its name.
            if template.takesArgument, let alias = launcher.usage.aliases["ql:\(record.id)"],
               let argument = QuicklinkMatcher.argument(after: alias, in: query.text) {
                found = (score: 2.5, argument: argument)
            }
            guard let found else { continue }
            items.append(builder.item(for: record, argument: found.argument, score: found.score))
        }
        for command in QuicklinksCommand.allCases {
            guard let score = query.match(command.title, keywords: command.keywords) else { continue }
            items.append(builder.item(for: command, score: score))
        }
        return items
    }

    func item(id: String) async -> LauncherItem? {
        let key = String(id.dropFirst(self.id.count + 1))
        let builder = QuicklinksItems(launcher: launcher, store: store)
        if let command = QuicklinksCommand(rawValue: key) { return builder.item(for: command, score: 0.5) }
        guard let record = store.record(id: key) else { return nil }
        return builder.item(for: record, argument: nil, score: 0.5)
    }
}

/// The feature's commands in root search.
enum QuicklinksCommand: String, CaseIterable {
    case create = "@create"
    case search = "@search"
    case fallbacks = "@fallbacks"
    case export = "@export"
    case `import` = "@import"

    var title: String {
        switch self {
        case .create: "Create Quicklink"
        case .search: "Search Quicklinks"
        case .fallbacks: "Manage Fallback Commands"
        case .export: "Export Launcher Data"
        case .import: "Import Launcher Data"
        }
    }

    var subtitle: String {
        switch self {
        case .create: "A link, a search URL with {query}, a folder or an app link"
        case .search: "Open, edit or delete your quicklinks"
        case .fallbacks: "What's offered below every search"
        case .export: "Quicklinks, favorites, aliases, hotkeys and snippets, to a file"
        case .import: "Adds a backup's quicklinks, aliases, hotkeys and snippets"
        }
    }

    var keywords: [String] {
        switch self {
        case .create: ["new quicklink", "add quicklink", "bookmark"]
        case .search: ["quicklinks", "bookmarks"]
        case .fallbacks: ["fallback", "web search"]
        case .export: ["backup", "export settings"]
        case .import: ["restore", "import settings", "import quicklinks"]
        }
    }

    var symbol: String {
        switch self {
        case .create: "link.badge.plus"
        case .search: "link"
        case .fallbacks: "arrow.turn.down.right"
        case .export: "square.and.arrow.up"
        case .import: "square.and.arrow.down"
        }
    }
}

/// Builds quicklink rows for root search and the feature's modes, with their actions.
struct QuicklinksItems {
    let launcher: Launcher
    let store: QuicklinksStore
    /// Where an editor or a confirmation started: back there when it's done (the panel hides while they're up).
    var reopen: QuicklinksReturn = .root

    func item(for command: QuicklinksCommand, score: Double) -> LauncherItem {
        let store = self.store
        let launcher = self.launcher
        let action: LauncherAction
        switch command {
        case .create:
            action = LauncherAction(id: "create", title: "Create Quicklink", symbol: command.symbol,
                                    keepsPanelOpen: true) { context in
                let back = reopen.whenDone(context)
                QuicklinksEditor.show(nil, store: store, launcher: launcher) { _ in back() }
            }
        case .search:
            action = LauncherAction(id: "search", title: "Search Quicklinks", symbol: command.symbol,
                                    keepsPanelOpen: true) { context in
                context.push(QuicklinksSearchMode(launcher: launcher, store: store))
            }
        case .fallbacks:
            action = LauncherAction(id: "settings", title: "Open Settings", symbol: "gearshape") { context in
                context.app.showSettings(.launcher)
            }
        case .export:
            action = LauncherAction(id: "export", title: "Export…", symbol: command.symbol) { _ in
                if let outcome = await QuicklinksBackupFiles.export(launcher: launcher, store: store) {
                    QuicklinksAlert.inform(outcome.title, detail: outcome.detail)
                }
            }
        case .import:
            action = LauncherAction(id: "import", title: "Import…", symbol: command.symbol) { _ in
                if let outcome = await QuicklinksBackupFiles.importFile(launcher: launcher, store: store) {
                    QuicklinksAlert.inform(outcome.title, detail: outcome.detail)
                }
            }
        }
        return LauncherItem(id: "ql:\(command.rawValue)", title: command.title, subtitle: command.subtitle,
                            icon: .symbol(command.symbol), accessory: "Command", score: score, actions: [action])
    }

    /// A quicklink's row. With an `argument` (typed after its name) ↩ opens it at once; without, a quicklink that
    /// takes one asks for it in the field first.
    func item(for record: QuicklinkRecord, argument: String?, score: Double,
              section: LauncherSection = .results) -> LauncherItem {
        let template = store.template(for: record)
        var values: [String: String] = [:]
        if let argument, let key = Self.typedKey(template) { values[key] = argument }
        let ready = !template.takesArgument
            || (argument != nil && QuicklinksArguments.next(in: template, values: values, askOptional: false) == nil)
        let store = self.store
        let launcher = self.launcher
        let reopen = self.reopen

        var actions: [LauncherAction] = [
            LauncherAction(id: "open", title: "Open", symbol: "arrow.up.forward.app", keepsPanelOpen: !ready) { context in
                QuicklinksArguments.proceed(record, values: values, askOptional: argument == nil, store: store,
                                            context: context)
            },
        ]
        if ready {
            actions.append(LauncherAction(id: "open-with", title: "Open With…", symbol: "arrow.up.right.square",
                                          keepsPanelOpen: true) { context in
                let filled = store.filled(record, arguments: values)
                guard let url = QuicklinkTemplate.destination(filled, home: NSHomeDirectory()) else {
                    context.flash("This isn't a link that can be opened")
                    return
                }
                context.push(QuicklinksOpenWithMode(record: record, url: url, store: store))
            })
        }
        actions += [
            LauncherAction(id: "copy-link", title: "Copy Link", symbol: "link", shortcut: .copyShift,
                           keepsPanelOpen: true) { context in
                context.copy(ready ? store.filled(record, arguments: values) : record.link)
            },
            LauncherAction(id: "copy-name", title: "Copy Name", symbol: "textformat", keepsPanelOpen: true) { context in
                context.copy(record.name)
            },
            LauncherAction(id: "edit", title: "Edit Quicklink…", symbol: "pencil", shortcut: LauncherShortcut("e", .command),
                           keepsPanelOpen: true) { context in
                let back = reopen.whenDone(context)
                QuicklinksEditor.show(record, store: store, launcher: launcher) { _ in back() }
            },
            LauncherAction(id: "duplicate", title: "Duplicate Quicklink", symbol: "plus.square.on.square",
                           shortcut: LauncherShortcut("d", .command), keepsPanelOpen: true) { context in
                let copy = store.duplicate(record)
                context.flash("Added “\(copy.name)”")
                context.refresh()
            },
            LauncherAction(id: "create", title: "Create Quicklink…", symbol: "link.badge.plus",
                           shortcut: LauncherShortcut("n", .command), keepsPanelOpen: true) { context in
                let back = reopen.whenDone(context)
                QuicklinksEditor.show(nil, store: store, launcher: launcher) { _ in back() }
            },
            LauncherAction(id: "delete", title: "Delete Quicklink…", symbol: "trash", shortcut: .deleteItem,
                           style: .destructive, keepsPanelOpen: true) { context in
                let back = reopen.whenDone(context)
                let sure = context.confirm("Delete “\(record.name)”?",
                                           message: "Its alias, hotkey and favorite go with it.",
                                           button: "Delete", destructive: true)
                if sure {
                    store.delete(record)
                    launcher.personalize { $0.forget("ql:\(record.id)") }
                    log("quicklinks: deleted one")
                }
                back()
                if sure { context.flash("Deleted “\(record.name)”") }
            },
        ]

        var metadata: [(label: String, value: String)] = [("Link", record.link)]
        if let keyword = record.keyword { metadata.append(("Keyword", keyword)) }
        if let bundle = record.openWith {
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            metadata.append(("Opens in", app.map { $0.deletingPathExtension().lastPathComponent } ?? bundle))
        }
        if let alias = launcher.usage.aliases["ql:\(record.id)"] { metadata.append(("Alias", alias)) }
        if let spec = launcher.usage.hotkeys["ql:\(record.id)"], let combo = KeyCombo(spec) {
            metadata.append(("Hotkey", combo.display))
        }
        let subtitle = argument.map { "“\($0)”" } ?? QuicklinkTemplate.display(record.link)
        return LauncherItem(id: "ql:\(record.id)", title: record.name, subtitle: subtitle, icon: store.icon(for: record),
                            accessory: record.keyword.map { "Quicklink · \($0)" } ?? "Quicklink", section: section,
                            score: score, actions: actions, metadata: metadata)
    }

    /// Where typed text goes: `{query}` if the link has it, else its first argument.
    static func typedKey(_ template: QuicklinkTemplate) -> String? {
        template.arguments.first { $0.key == "query" }?.key ?? template.arguments.first?.key
    }
}

/// Where an action that hides the panel (an editor, a question) leaves you when it's done.
enum QuicklinksReturn {
    /// Root search, as it was.
    case root
    /// Search Quicklinks.
    case search(Launcher, QuicklinksStore)

    /// What to do when it's done: show the panel again (in its mode) if it was up when the action started. A hotkey
    /// or a link that ran it leaves the panel closed, and the app that was in front gets the keyboard back.
    func whenDone(_ context: LauncherContext) -> () -> Void {
        let wasVisible = context.isPanelVisible
        let front = NSWorkspace.shared.frontmostApplication
        return {
            guard wasVisible else { return QuicklinksAlert.returnFocus(to: front) }
            context.show()
            if case .search(let launcher, let store) = self {
                context.push(QuicklinksSearchMode(launcher: launcher, store: store))
            }
        }
    }
}

/// Filling in a quicklink's arguments one at a time, then opening it.
enum QuicklinksArguments {
    /// The next argument to ask for: the first one without a value that's required (or any, with `askOptional`).
    static func next(in template: QuicklinkTemplate, values: [String: String], askOptional: Bool) -> Int? {
        template.arguments.firstIndex { argument in
            values[argument.key] == nil && (askOptional || argument.isRequired)
        }
    }

    /// Asks for the next argument in the panel, or opens the quicklink when it has them all.
    static func proceed(_ record: QuicklinkRecord, values: [String: String], askOptional: Bool, store: QuicklinksStore,
                        context: LauncherContext) {
        let template = store.template(for: record)
        if let index = next(in: template, values: values, askOptional: askOptional) {
            context.push(QuicklinkArgumentMode(record: record, index: index, values: values, askOptional: askOptional,
                                               store: store))
            return
        }
        Task {
            if let problem = await store.open(record, arguments: values) {
                context.show()
                context.flash(problem)
            }
        }
    }
}

/// One argument of a quicklink, typed in the panel's field: the field says what it wants ("Search Google…") and the
/// one row shows where ↩ goes. A quicklink with several arguments asks for each in turn; Esc goes back one.
final class QuicklinkArgumentMode: LauncherMode {
    private let record: QuicklinkRecord
    private let template: QuicklinkTemplate
    private let index: Int
    private let values: [String: String]
    private let askOptional: Bool
    private let store: QuicklinksStore

    init(record: QuicklinkRecord, index: Int, values: [String: String], askOptional: Bool, store: QuicklinksStore) {
        self.record = record
        template = store.template(for: record)
        self.index = index
        self.values = values
        self.askOptional = askOptional
        self.store = store
    }

    private var argument: QuicklinkTemplate.Argument { template.arguments[index] }

    var title: String {
        guard template.arguments.count > 1, let label = argument.label else { return record.name }
        return "\(record.name) · \(label)"
    }

    var placeholder: String { QuicklinkTemplate.prompt(for: argument, quicklinkName: record.name) }
    var icon: LauncherIcon { store.icon(for: record) }

    var statusHint: String? {
        template.arguments.count > 1 ? "\(index + 1) of \(template.arguments.count)" : QuicklinkTemplate.display(record.link)
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        if !argument.options.isEmpty {
            let choices = argument.options.compactMap { option -> (String, Double)? in
                if query.isEmpty { return (option, 0.5) }
                return query.match(option).map { (option, $0) }
            }
            return choices.enumerated()
                .map { offset, choice in
                    row(value: choice.0, id: "ql:\(record.id):option:\(offset)", title: choice.0, score: choice.1)
                }
                .sorted { $0.score > $1.score }
        }
        let text = query.text
        let title: String
        if !text.isEmpty {
            title = text
        } else if let fallback = argument.defaultValue, !fallback.isEmpty {
            title = "“\(fallback)” (the default)"
        } else {
            title = placeholder
        }
        return [row(value: text, id: "ql:\(record.id)", title: title, score: 1)]
    }

    private func row(value: String, id: String, title: String, score: Double) -> LauncherItem {
        var filledValues = values
        filledValues[argument.key] = value
        let rest = QuicklinksArguments.next(in: template, values: filledValues, askOptional: askOptional)
        let missing = value.isEmpty && argument.isRequired
        let record = self.record
        let store = self.store
        let askOptional = self.askOptional
        let needed = placeholder
        var actions = [
            LauncherAction(id: "open", title: rest == nil ? "Open" : "Next", symbol: rest == nil ? "arrow.up.forward.app"
                : "arrow.right", keepsPanelOpen: missing || rest != nil) { context in
                guard !missing else {
                    context.flash(needed.replacingOccurrences(of: "…", with: "") + ": type it first")
                    return
                }
                QuicklinksArguments.proceed(record, values: filledValues, askOptional: askOptional, store: store,
                                            context: context)
            },
        ]
        let preview = QuicklinkTemplate.display(store.filled(record, arguments: filledValues, readClipboard: false))
        if rest == nil, !missing {
            actions.append(LauncherAction(id: "copy-link", title: "Copy Link", symbol: "link", shortcut: .copyShift,
                                          keepsPanelOpen: true) { context in
                context.copy(store.filled(record, arguments: filledValues))
            })
        }
        // The final step counts as using the quicklink (frecency); choosing an option on the way doesn't.
        return LauncherItem(id: id, title: title, subtitle: preview, icon: store.icon(for: record),
                            accessory: rest == nil ? nil : "Next: \(nextLabel(rest!))", score: score,
                            actions: actions, detail: .summary, tracksUsage: rest == nil && id == "ql:\(record.id)")
    }

    private func nextLabel(_ index: Int) -> String {
        template.arguments[index].label ?? "search text"
    }

    var keysHint: String? {
        var filled = values
        filled[argument.key] = argument.defaultValue ?? "x"
        let last = QuicklinksArguments.next(in: template, values: filled, askOptional: askOptional) == nil
        return last ? "↩ Open   ⇧⌘C Copy Link   Esc Back" : "↩ Next   Esc Back"
    }
}

/// Search Quicklinks: every quicklink, to open, edit, duplicate or delete.
final class QuicklinksSearchMode: LauncherMode {
    private let launcher: Launcher
    private let store: QuicklinksStore

    init(launcher: Launcher, store: QuicklinksStore) {
        self.launcher = launcher
        self.store = store
    }

    var title: String { "Quicklinks" }
    var placeholder: String { "Search your quicklinks…" }
    var icon: LauncherIcon { .symbol("link") }
    var keysHint: String? { "↩ Open   ⌘E Edit   ⌘N New   ⌃X Delete   ⌘K Actions" }

    var statusHint: String? {
        store.links.count == 1 ? "1 quicklink" : "\(store.links.count) quicklinks"
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        var builder = QuicklinksItems(launcher: launcher, store: store)
        builder.reopen = .search(launcher, store)
        let section = LauncherSection.named("Quicklinks", order: 0)
        var rows: [LauncherItem] = []
        for record in store.links {
            let keywords = [record.keyword, QuicklinkTemplate.display(record.link)].compactMap { $0 }
            guard query.isEmpty || query.match(record.name, keywords: keywords) != nil else { continue }
            let score = query.isEmpty ? 0.5 : query.match(record.name, keywords: keywords) ?? 0
            rows.append(builder.item(for: record, argument: nil, score: score, section: section))
        }
        rows.sort { a, b in
            a.score != b.score ? a.score > b.score : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        var create = builder.item(for: .create, score: 0)
        create.section = .named("Actions", order: 1)
        return rows + [create]
    }
}

/// Open With: the apps that can open a quicklink's link; ↩ opens it in one, ⌘↩ makes it the quicklink's app.
final class QuicklinksOpenWithMode: LauncherMode {
    private let record: QuicklinkRecord
    private let url: URL
    private let store: QuicklinksStore
    private let apps: [URL]

    init(record: QuicklinkRecord, url: URL, store: QuicklinksStore) {
        self.record = record
        self.url = url
        self.store = store
        apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    var title: String { "Open \(record.name) With" }
    var placeholder: String { "Search apps…" }
    var icon: LauncherIcon { store.icon(for: record) }
    var keysHint: String? { "↩ Open   ⌘↩ Always Open With   Esc Back" }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        let section = LauncherSection.named("Applications", order: 0)
        return apps.compactMap { app -> LauncherItem? in
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            guard query.isEmpty || query.match(name) != nil else { return nil }
            let bundleID = Bundle(url: app)?.bundleIdentifier
            let record = self.record
            let store = self.store
            let url = self.url
            var actions = [
                LauncherAction(id: "open", title: "Open in \(name)", symbol: "arrow.up.forward.app") { context in
                    if let problem = await QuicklinksStore.open(url, withApplicationAt: app) {
                        context.show()
                        context.flash(problem)
                    }
                },
            ]
            if let bundleID {
                actions.append(LauncherAction(id: "always", title: "Always Open in \(name)", symbol: "pin",
                                              keepsPanelOpen: true) { context in
                    var changed = record
                    changed.openWith = bundleID
                    store.save(changed)
                    context.flash("“\(record.name)” opens in \(name) from now on")
                    context.popToRoot()
                })
            }
            let score = query.isEmpty ? (app == defaultApp ? 1 : 0.5) : query.match(name) ?? 0
            return LauncherItem(id: "ql:\(record.id):app:\(app.path)", title: name,
                                subtitle: app == defaultApp ? "Default app" : tildePath(app.deletingLastPathComponent().path),
                                icon: .file(app), section: section, score: score, actions: actions, tracksUsage: false)
        }
        .sorted { a, b in
            a.score != b.score ? a.score > b.score : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

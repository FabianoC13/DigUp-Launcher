import AppKit
import DigUpKit
import SwiftUI

/// What was typed in the launcher, trimmed and normalized once for every provider.
struct LauncherQuery: Sendable {
    /// Exactly what's in the field.
    let raw: String
    /// Without leading and trailing whitespace.
    let text: String
    /// Lowercased, accents folded (`FuzzyMatch.normalize`).
    let normalized: String

    /// Normalized once for every name it's matched against.
    let fuzzy: FuzzyMatch.Query

    init(_ raw: String) {
        self.raw = raw
        text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        fuzzy = FuzzyMatch.Query(text)
        normalized = fuzzy.normalized
    }

    var isEmpty: Bool { text.isEmpty }

    /// How well `name` (or one of its `keywords`) matches what was typed: 0…1, nil for no match.
    func match(_ name: String, keywords: [String] = []) -> Double? {
        FuzzyMatch.best(fuzzy, name: name, keywords: keywords)
    }
}

/// An item's picture in the list and the preview.
enum LauncherIcon {
    /// The Finder icon of a file, folder or app.
    case file(URL)
    /// An SF Symbol, tinted (nil: the accent gradient DigUp uses).
    case symbol(String, Color? = nil)
    case image(NSImage)
    /// One or two characters drawn big ("=", "€", "A").
    case glyph(String)
    /// A swatch (the clipboard's colors).
    case color(Color)
}

/// A key combination shown next to an action and matched against key presses while its item is selected.
struct LauncherShortcut: Equatable {
    /// A character ("c", "k", "1") or a named key: "return", "delete", "tab", "space", "up", "down".
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
    }

    static let returnKey = LauncherShortcut("return")
    static let commandReturn = LauncherShortcut("return", .command)
    static let commandOptionReturn = LauncherShortcut("return", [.command, .option])
    static let copy = LauncherShortcut("c", .command)
    static let copyShift = LauncherShortcut("c", [.command, .shift])
    static let deleteItem = LauncherShortcut("x", .control)

    /// "⌘↩", "⌃X", "⇧⌘C".
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case "return": text += "↩"
        case "delete": text += "⌫"
        case "tab": text += "⇥"
        case "space": text += "Space"
        case "up": text += "↑"
        case "down": text += "↓"
        default: text += key.uppercased()
        }
        return text
    }

    /// Whether this key press is this shortcut.
    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == modifiers else { return false }
        switch key {
        case "return": return event.keyCode == 36 || event.keyCode == 76
        case "delete": return event.keyCode == 51
        case "tab": return event.keyCode == 48
        case "space": return event.keyCode == 49
        case "up": return event.keyCode == 126
        case "down": return event.keyCode == 125
        default: return event.charactersIgnoringModifiers?.lowercased() == key
        }
    }
}

/// Something an item can do: the first is ↩, the second ⌘↩, all of them are in the action panel (⌘K).
struct LauncherAction: Identifiable {
    enum Style { case normal, destructive }

    /// Stable within its item ("open", "copy", "quit").
    let id: String
    let title: String
    var symbol: String?
    /// Shown in the action panel, and run when pressed while the item is selected. ↩ and ⌘↩ need none: the first two
    /// actions get them.
    var shortcut: LauncherShortcut?
    var style: Style = .normal
    /// The panel stays up after it runs (a mode it pushes, a list it refreshes). Otherwise the panel hides first and
    /// the app you came from gets the keyboard back before `run` starts.
    var keepsPanelOpen = false
    let run: @MainActor (LauncherContext) async -> Void

    init(id: String, title: String, symbol: String? = nil, shortcut: LauncherShortcut? = nil, style: Style = .normal,
         keepsPanelOpen: Bool = false, run: @escaping @MainActor (LauncherContext) async -> Void) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.style = style
        self.keepsPanelOpen = keepsPanelOpen
        self.run = run
    }
}

/// Where an item is listed: sections show in `order`, before or after DigUp's own file results.
struct LauncherSection: Hashable {
    let id: String
    let title: String
    let order: Int
    /// Below DigUp's meaning-search results (names of files, "Search Google for…").
    var afterFiles = false

    /// A calculator answer, a conversion, a definition: one big row on top.
    static let answer = LauncherSection(id: "answer", title: "Answer", order: 0)
    static let favorites = LauncherSection(id: "favorites", title: "Favorites", order: 1)
    static let suggestions = LauncherSection(id: "suggestions", title: "Suggestions", order: 2)
    /// Apps, commands, settings, quicklinks, snippets, running apps: ranked together.
    static let results = LauncherSection(id: "results", title: "Results", order: 3)
    /// Files whose names match (Spotlight's index).
    static let files = LauncherSection(id: "files", title: "Files by Name", order: 10, afterFiles: true)
    /// "Search Google for “…”", "Ask AI": what to do when nothing above is it.
    static let fallback = LauncherSection(id: "fallback", title: "Use with…", order: 20, afterFiles: true)

    /// A section of a mode's own list ("Pinned", "Today").
    static func named(_ title: String, order: Int) -> LauncherSection {
        LauncherSection(id: "named:\(title)", title: title, order: order)
    }
}

/// What the preview pane on the right shows for an item.
enum LauncherDetail {
    /// The icon, title and subtitle, big, with the metadata.
    case summary
    /// A result in big type (the calculator: "1,234.5", with "= 1234.5" under it).
    case answer(String, caption: String?)
    case text(String, monospaced: Bool = false)
    /// Markdown (inline formatting and paragraphs).
    case markdown(String)
    case image(URL)
    /// A file: its thumbnail.
    case file(URL)
    case custom(AnyView)
}

/// One row of the launcher: an app, a command, an answer, a clipboard entry…
struct LauncherItem: Identifiable {
    /// "<provider id>:<stable key>" ("app:/Applications/Safari.app", "cmd:lock-screen"). The prefix routes favorites,
    /// aliases and hotkeys back to the provider that made it (`LauncherProvider.item(id:)`).
    let id: String
    var title: String
    var subtitle: String?
    var icon: LauncherIcon
    /// The tag on the right of the row: "Application", "Command", "System Settings".
    var accessory: String?
    var section: LauncherSection = .results
    /// 0…1 from the provider (usually `LauncherQuery.match`); the launcher adds frecency, picks and aliases.
    var score: Double = 0.5
    /// The first runs on ↩, the second on ⌘↩; all are in the action panel (⌘K).
    var actions: [LauncherAction]
    var detail: LauncherDetail = .summary
    /// Shown under the preview: ("Version", "17.4"), ("Path", "~/Applications").
    var metadata: [(label: String, value: String)] = []
    /// Runs count towards frecency, and favorites, aliases and hotkeys are offered. Off for one-off things (an answer,
    /// a clipboard entry, a fallback).
    var tracksUsage = true

    init(id: String, title: String, subtitle: String? = nil, icon: LauncherIcon, accessory: String? = nil,
         section: LauncherSection = .results, score: Double = 0.5, actions: [LauncherAction],
         detail: LauncherDetail = .summary, metadata: [(label: String, value: String)] = [], tracksUsage: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accessory = accessory
        self.section = section
        self.score = score
        self.actions = actions
        self.detail = detail
        self.metadata = metadata
        self.tracksUsage = tracksUsage
    }

    var primary: LauncherAction? { actions.first }
    var secondary: LauncherAction? { actions.dropFirst().first }

    /// The part of the id after the provider's prefix.
    var key: String { id.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? id }
    var providerID: String { String(id.prefix { $0 != ":" }) }
}

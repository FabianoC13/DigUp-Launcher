import AppKit
import DigUpKit
import SwiftUI

/// A source of root-search items: apps, commands, an answer… Each feature brings one or more (`LauncherFeature`).
///
/// `items(for:)` runs on every keystroke, all providers at once, and each one's results show as soon as they're ready,
/// so a slow one (the network, Spotlight) never holds up a fast one. Check `Task.isCancelled` after any wait: the next
/// keystroke cancels the last search.
protocol LauncherProvider: AnyObject {
    /// The prefix of every item id it makes ("app", "cmd", "calc").
    var id: String { get }
    /// Root-search items for what's typed. Usually nothing when `query.isEmpty` (favorites and suggestions come from
    /// `item(id:)`).
    func items(for query: LauncherQuery) async -> [LauncherItem]
    /// The item with this id, as it is now, for favorites, suggestions, aliases and hotkeys; nil when it's gone or
    /// can't be shown out of a search.
    func item(id: String) async -> LauncherItem?
}

extension LauncherProvider {
    func item(id: String) async -> LauncherItem? { nil }
}

/// A view the launcher pushes over the root search, like Raycast's commands that open their own list: Clipboard
/// History, Quick AI, My Schedule. Esc (or ⌫ in an empty field) goes back.
protocol LauncherMode: AnyObject {
    var title: String { get }
    var placeholder: String { get }
    var icon: LauncherIcon { get }
    /// The list for what's typed (list modes). Modes with their own view return nothing.
    func items(for query: LauncherQuery) async -> [LauncherItem]
    /// A view in place of the list and the preview (Quick AI's conversation); nil for the standard list.
    func makeView(context: LauncherContext) -> AnyView?
    /// A key press, before the panel's own keys (except Esc and the action panel's). True when handled.
    func handle(_ event: NSEvent, query: String, context: LauncherContext) -> Bool
    /// The footer's keys ("↩ Paste   ⌘K Actions"); nil for the selected item's.
    var keysHint: String? { get }
    /// The footer's status ("12 entries"); nil for a count of the list.
    var statusHint: String? { get }
    /// It was popped, or the panel closed.
    func didClose()
}

extension LauncherMode {
    func items(for query: LauncherQuery) async -> [LauncherItem] { [] }
    func makeView(context: LauncherContext) -> AnyView? { nil }
    func handle(_ event: NSEvent, query: String, context: LauncherContext) -> Bool { false }
    var keysHint: String? { nil }
    var statusHint: String? { nil }
    func didClose() {}
}

/// A feature of the launcher (apps, the calculator, clipboard history…): its providers, what it runs in the
/// background, and its part of Settings → Launcher. Listed in `LauncherFeatures.all`.
protocol LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider]
    /// At launch, after the providers exist: watchers, hotkeys, caches.
    static func start(_ launcher: Launcher)
    /// Its section of Settings → Launcher (nil: none).
    static var settingsTitle: String? { get }
    static func settingsView(_ launcher: Launcher) -> AnyView
}

extension LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] { [] }
    static func start(_ launcher: Launcher) {}
    static var settingsTitle: String? { nil }
    static func settingsView(_ launcher: Launcher) -> AnyView { AnyView(EmptyView()) }
}

/// The root search: runs every provider for what's typed, ranks what comes back with what it has learned
/// (`LauncherUsage`: frecency, picks, aliases), and shows favorites and suggestions when nothing is typed.
final class Launcher {
    private(set) var providers: [any LauncherProvider] = []
    private(set) var usage: LauncherUsage
    /// Where the launcher's features keep their files (clipboard history, snippets, notes…).
    /// `-launcherDir <path>` points dev and test runs somewhere else, so they never touch the real history.
    static let directory: URL = {
        if let path = UserDefaults.standard.string(forKey: "launcherDir"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return AppSettings.supportDirectory.appendingPathComponent("Launcher", isDirectory: true)
    }()
    private static var usageFile: URL { directory.appendingPathComponent("usage.json") }
    /// The panel's context, for running items outside a search (hotkeys, deeplinks).
    weak var panel: SearchPanelController?
    private var saveTask: Task<Void, Never>?
    /// Called after favorites, aliases or hotkeys change (the hotkeys re-register).
    var onPersonalizationChanged: [() -> Void] = []

    static let resultsLimit = 40
    /// How long the first results of a keystroke wait for slower providers.
    static let firstUpdateWait: Duration = .milliseconds(40)
    /// A provider slower than this is logged (each keystroke runs them all).
    static let slowProvider: Duration = .milliseconds(8)
    static let suggestionsLimit = 8

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.usageFile),
           let saved = try? JSONDecoder().decode(LauncherUsage.self, from: data) {
            usage = saved
        } else {
            usage = LauncherUsage()
        }
    }

    func start() {
        providers = LauncherFeatures.all.flatMap { $0.providers(self) }
        for feature in LauncherFeatures.all { feature.start(self) }
        log("launcher: \(providers.count) providers (\(providers.map(\.id).joined(separator: ", ")))")
    }

    // MARK: Searching

    /// Searches every provider; `update` gets the ranked list each time one more provider has answered, and whether
    /// that was the last one. Cancel the returned tasks when the query changes.
    func search(_ query: LauncherQuery, update: @escaping ([LauncherItem], _ final: Bool) -> Void) -> [Task<Void, Never>] {
        if query.isEmpty {
            return [Task {
                let found = await suggestions()
                guard !Task.isCancelled else { return }
                update(found, true)
            }]
        }
        let parts = Parts()
        let alias = usage.item(forAlias: query.text)
        parts.waiting = providers.count + (alias == nil ? 0 : 1)
        // The first update waits for every provider or `firstUpdateWait`, whichever comes first, so the list doesn't
        // flash with only the quickest provider's rows; after that, each answer shows as it comes.
        func publish(force: Bool = false) {
            guard force || parts.waiting == 0 || parts.deadlinePassed else { return }
            update(rank(parts.all, query: query), parts.waiting == 0)
        }
        var tasks = providers.map { provider in
            Task {
                let started = ContinuousClock.now
                let found = await provider.items(for: query)
                let took = ContinuousClock.now - started
                if took > Self.slowProvider { log("launcher: \(provider.id) took \(took.formatted(.units(allowed: [.milliseconds]))) for \"\(query.text)\"") }
                guard !Task.isCancelled else { return }
                parts.byProvider[provider.id] = found
                parts.waiting -= 1
                publish()
            }
        }
        // An alias puts its item first, whatever its name.
        if let alias {
            tasks.append(Task {
                let found = await item(id: alias)
                guard !Task.isCancelled else { return }
                if var item = found {
                    item.score = 3
                    item.section = .results
                    parts.byProvider["\u{0}alias"] = [item]
                }
                parts.waiting -= 1
                publish()
            })
        }
        tasks.append(Task {
            try? await Task.sleep(for: Self.firstUpdateWait)
            guard !Task.isCancelled, parts.waiting > 0 else { return }
            parts.deadlinePassed = true
            publish(force: true)
        })
        return tasks
    }

    /// The provider results of one search, as they come in.
    private final class Parts {
        var byProvider: [String: [LauncherItem]] = [:]
        var waiting = 0
        var deadlinePassed = false
        var all: [LauncherItem] { byProvider.keys.sorted().flatMap { byProvider[$0]! } }
    }

    /// Learned boosts on top of each provider's score, the best item per id, sections in order, best first in each.
    func rank(_ items: [LauncherItem], query: LauncherQuery) -> [LauncherItem] {
        var best: [String: LauncherItem] = [:]
        for var item in items {
            if item.tracksUsage, item.section == .results {
                item.score += 0.35 * usage.frecency(item.id) + 0.5 * usage.pickBoost(item.id, query: query.text)
            }
            if let existing = best[item.id], existing.score >= item.score { continue }
            best[item.id] = item
        }
        let sorted = best.values.sorted { a, b in
            if a.section.order != b.section.order { return a.section.order < b.section.order }
            if a.score != b.score { return a.score > b.score }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        var counts: [String: Int] = [:]
        return sorted.filter { item in
            counts[item.section.id, default: 0] += 1
            return item.section != .results || counts[item.section.id]! <= Self.resultsLimit
        }
    }

    /// With nothing typed: favorites, then what you use most.
    func suggestions() async -> [LauncherItem] {
        var items: [LauncherItem] = []
        var seen = Set<String>()
        for id in usage.favorites {
            guard var item = await item(id: id) else { continue }
            item.section = .favorites
            items.append(item)
            seen.insert(id)
        }
        for id in usage.recent(limit: Self.suggestionsLimit * 2) where !seen.contains(id) {
            guard items.count - seen.count < Self.suggestionsLimit, var item = await item(id: id) else { continue }
            item.section = .suggestions
            items.append(item)
        }
        return items
    }

    /// The item with this id, from the provider its prefix names.
    func item(id: String) async -> LauncherItem? {
        let prefix = String(id.prefix { $0 != ":" })
        for provider in providers where provider.id == prefix {
            if let item = await provider.item(id: id) { return item }
        }
        return nil
    }

    /// Runs an item's first action outside a search (a hotkey, a deeplink).
    func run(itemID id: String) async {
        guard let item = await item(id: id), let action = item.primary else {
            log("launcher: nothing to run for \(id)")
            return
        }
        recordUse(item, query: nil)
        if let panel {
            panel.run(action, of: item, recordUsage: false)
        }
    }

    // MARK: What it learns

    func recordUse(_ item: LauncherItem, query: String?) {
        guard item.tracksUsage else { return }
        usage.recordUse(item.id, query: query)
        save()
    }

    /// Favorites, aliases and hotkeys: change and save.
    func personalize(_ change: (inout LauncherUsage) -> Void) {
        change(&usage)
        save()
        for observer in onPersonalizationChanged { observer() }
    }

    private func save() {
        saveTask?.cancel()
        let usage = self.usage
        let file = Self.usageFile
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let data = try? JSONEncoder().encode(usage)
            await Task.detached { try? data?.write(to: file, options: .atomic) }.value
        }
    }
}

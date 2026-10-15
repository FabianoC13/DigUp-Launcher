import AppKit
import DigUpKit

/// "file": files and folders whose names match what's typed (Spotlight, in root search's Files by Name section),
/// the contents of a typed path ("~/Documents/"), and the Search Files command.
final class AppsFilesProvider: LauncherProvider {
    let id = "file"

    /// Root search shows this many files; Search Files shows more.
    static let rootLimit = 8
    /// Typing settles for this long before Spotlight is asked.
    static let debounce: Duration = .milliseconds(150)

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        var items: [LauncherItem] = []
        if let score = query.match(AppsFileSearchCommand.title, keywords: AppsFileSearchCommand.keywords) {
            items.append(AppsFileSearchCommand.item(score: score, query: nil))
        }
        let home = NSHomeDirectory()
        if let path = AppsFileSearchRules.pathQuery(query.text, home: home) {
            return items + (await AppsPathBrowser.items(folder: path.folder, prefix: path.prefix, home: home))
        }
        guard AppsFeature.preferences.value.filesInRootSearch,
              query.text.count >= AppsFileSearchRules.minimumQueryLength else { return items }
        try? await Task.sleep(for: Self.debounce)
        guard !Task.isCancelled else { return [] }
        let found = await AppsFileFinder.find(query.text, limit: Self.rootLimit, includeApps: false)
        guard !Task.isCancelled else { return [] }
        items += found.map { AppsFileItems.item($0.hit, score: $0.score) }
        if !found.isEmpty {
            items.append(AppsFileSearchCommand.item(score: 0.05, query: query.text))
        }
        return items
    }

    func item(id: String) async -> LauncherItem? {
        let key = String(id.dropFirst(self.id.count + 1))
        if key == AppsFileSearchCommand.key { return AppsFileSearchCommand.item(score: 0.5, query: nil) }
        guard key.hasPrefix("/") else { return nil }
        let hit = await Task.detached(priority: .userInitiated) { AppsFileHit(path: key) }.value
        return hit.map { AppsFileItems.item($0, score: 0.5) }
    }
}

/// Search Files (Raycast's File Search): a list of up to 50 files by name, recent files when nothing's typed.
enum AppsFileSearchCommand {
    static let key = "search"
    static let title = "Search Files"
    static let keywords = ["find files", "file search", "spotlight", "documents", "folders"]

    /// The command, or (with `query`) a row under root search's files that continues the search in it.
    static func item(score: Double, query: String?) -> LauncherItem {
        LauncherItem(
            id: query == nil ? "file:" + key : "file:search-more",
            title: query.map { "Search Files for “\($0)”" } ?? title,
            subtitle: query == nil ? "Find files and folders by name" : "More files, with details",
            icon: .symbol("doc.text.magnifyingglass"), accessory: "Command",
            section: query == nil ? .results : .files, score: score,
            actions: [
                LauncherAction(id: "open", title: "Search Files", symbol: "magnifyingglass", keepsPanelOpen: true) {
                    context in
                    context.push(AppsFileSearchMode(), query: query ?? "")
                },
            ],
            tracksUsage: query == nil)
    }
}

/// Typed paths: "~/Doc" lists the folders and files in your home folder starting with "Doc"; "~/Documents/" lists
/// what's in Documents. Hidden files show only when what's typed starts with a dot.
enum AppsPathBrowser {
    static let limit = 60

    static func items(folder: String, prefix: String, home: String) async -> [LauncherItem] {
        let listing = await Task.detached(priority: .userInitiated) { () -> (folder: AppsFileHit?, [AppsFileHit])? in
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            let options: FileManager.DirectoryEnumerationOptions = prefix.hasPrefix(".") ? [] : [.skipsHiddenFiles]
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(AppsFileHit.keys), options: options) else { return nil }
            return (AppsFileHit(path: folder), children.compactMap { AppsFileHit(path: $0.path) })
        }.value
        guard !Task.isCancelled, let (folderHit, children) = listing else { return [] }
        var matches: [(hit: AppsFileHit, score: Double)] = []
        for child in children {
            if prefix.isEmpty {
                matches.append((child, 0.9))
            } else if let score = FuzzyMatch.score(prefix, child.name), score >= 0.5 {
                matches.append((child, 0.6 + 0.4 * score))
            }
        }
        matches.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.hit.name.localizedStandardCompare(right.hit.name) == .orderedAscending
        }
        let section = LauncherSection.named(AppsFormat.tildePath(folder, home: home), order: 3)
        var items: [LauncherItem] = []
        if prefix.isEmpty, let folderHit {
            items.append(folderItem(folderHit, home: home))
        }
        // Scores fall a little down the list so the launcher keeps this order.
        for (index, match) in matches.prefix(limit).enumerated() {
            let score = match.score - Double(index) * 0.0005
            items.append(AppsFileItems.item(match.hit, score: score, section: section, browsing: true))
        }
        return items
    }

    /// The typed folder itself, on top: open it, or go up a level.
    private static func folderItem(_ hit: AppsFileHit, home: String) -> LauncherItem {
        var item = AppsFileItems.item(hit, score: 0.95, section: .results)
        // It's already what's listed.
        item.actions.removeAll { $0.id == "enter" }
        if let parent = AppsFileSearchRules.parentQuery(of: hit.path, home: home) {
            item.actions.insert(LauncherAction(id: "parent", title: "Go to Enclosing Folder", symbol: "arrow.up",
                                               shortcut: LauncherShortcut("up", .command), keepsPanelOpen: true) {
                context in
                context.query = parent
            }, at: 1)
        }
        return item
    }
}

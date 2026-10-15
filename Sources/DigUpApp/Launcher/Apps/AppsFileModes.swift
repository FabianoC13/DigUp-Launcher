import AppKit
import DigUpKit
import UniformTypeIdentifiers

/// Search Files: up to 50 files and folders whose names match, with the preview and details on the right; the files
/// opened lately when nothing's typed. Typed paths list folders as in root search.
final class AppsFileSearchMode: LauncherMode {
    static let limit = 50
    static let recentDays = 14

    var title: String { "Search Files" }
    var placeholder: String { "Search files and folders by name…" }
    var icon: LauncherIcon { .symbol("doc.text.magnifyingglass") }
    var keysHint: String? { "↩ Open  ⌘↩ Show in Finder  ⇧⌘O Open With" }
    private(set) var statusHint: String?

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let home = NSHomeDirectory()
        if query.isEmpty {
            let recent = await AppsFileFinder.recent(days: Self.recentDays, limit: Self.limit)
            guard !Task.isCancelled else { return [] }
            statusHint = recent.isEmpty ? "Nothing opened lately" : nil
            let section = LauncherSection.named("Recent Files", order: 0)
            return recent.enumerated().map { index, hit in
                AppsFileItems.item(hit, score: 1 - Double(index) * 0.001, section: section)
            }
        }
        if let path = AppsFileSearchRules.pathQuery(query.text, home: home) {
            statusHint = nil
            return await AppsPathBrowser.items(folder: path.folder, prefix: path.prefix, home: home)
        }
        guard query.text.count >= AppsFileSearchRules.minimumQueryLength else {
            statusHint = "Type at least \(AppsFileSearchRules.minimumQueryLength) characters"
            return []
        }
        try? await Task.sleep(for: AppsFilesProvider.debounce)
        guard !Task.isCancelled else { return [] }
        let found = await AppsFileFinder.find(query.text, limit: Self.limit, includeApps: true)
        guard !Task.isCancelled else { return [] }
        statusHint = found.isEmpty ? "No files named like “\(query.text)”" : "\(found.count) files"
        let section = LauncherSection.named("Files", order: 0)
        return found.map { AppsFileItems.item($0.hit, score: $0.score, section: section) }
    }
}

/// Open With…: the apps that can open a file, its default first; with something typed, any other app too.
final class AppsOpenWithMode: LauncherMode {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    var title: String { "Open With" }
    var placeholder: String { "Open “\(url.lastPathComponent)” with…" }
    var icon: LauncherIcon { .file(url) }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let file = url
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: file)?.standardizedFileURL
        let capable = NSWorkspace.shared.urlsForApplications(toOpen: file).map(\.standardizedFileURL)
        var seen = Set<String>()
        var items: [LauncherItem] = []
        for (index, app) in capable.enumerated() where seen.insert(app.path).inserted {
            let name = AppsFeature.catalog.entry(path: app.path)?.name ?? AppsScanner.displayName(app.path)
            let score: Double
            if query.isEmpty {
                score = app == defaultApp ? 1 : 0.9 - Double(index) * 0.001
            } else if let match = query.match(name) {
                score = match
            } else {
                continue
            }
            let section = app == defaultApp ? LauncherSection.named("Default", order: 0)
                : .named("Recommended", order: 1)
            items.append(item(app: app, name: name, score: score, section: section))
        }
        // Any other app, for a file type no app claims or one opened unusually ("Open With TextEdit").
        if !query.isEmpty {
            for entry in AppsFeature.catalog.entries where !seen.contains(entry.path) {
                guard let match = query.match(entry.name, keywords: entry.keywords) else { continue }
                items.append(item(app: entry.url, name: entry.name, score: match * 0.9,
                                  section: .named("Other Applications", order: 2)))
            }
        }
        return items
    }

    private func item(app: URL, name: String, score: Double, section: LauncherSection) -> LauncherItem {
        let file = url
        let open = LauncherAction(id: "open", title: "Open with \(name)", symbol: "arrow.up.forward.app") { context in
            do {
                _ = try await NSWorkspace.shared.open([file], withApplicationAt: app,
                                                      configuration: NSWorkspace.OpenConfiguration())
            } catch {
                AppsFeature.report("\(name) couldn't open \(file.lastPathComponent).",
                                   message: error.localizedDescription, context: context)
            }
        }
        let makeDefault = LauncherAction(id: "default", title: "Always Open This Kind of File with \(name)",
                                         symbol: "star", keepsPanelOpen: true) { context in
            guard let type = (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType else {
                context.flash("This file's type isn't known")
                return
            }
            guard context.confirm("Open every \(type.localizedDescription ?? "file of this kind") with \(name)?",
                                  message: "Like Finder's Get Info → Open With → Change All.",
                                  button: "Change All") else { return }
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
                context.flash("\(name) now opens these files")
                context.refresh()
            } catch {
                AppsFeature.report("Couldn't change the default app.", message: error.localizedDescription,
                                   context: context)
            }
        }
        return LauncherItem(id: "app:" + app.path, title: name, icon: .file(app), accessory: "Application",
                            section: section, score: score, actions: [open, makeDefault],
                            metadata: [("Location", AppsFormat.tildePath(app.deletingLastPathComponent().path,
                                                                         home: NSHomeDirectory()))],
                            tracksUsage: false)
    }
}

import AppKit
import DigUpKit
import SwiftUI

/// Fallback commands ("fb:<id>"): what to do with the text when nothing above is it. Search Google, Ask AI, Search
/// DuckDuckGo, Search Maps, Search Files, and quicklinks that take one argument, in the order and with the switches set
/// in Settings. Below the file results, under every search.
final class QuicklinksFallbackProvider: LauncherProvider {
    let id = "fb"
    private let store: QuicklinksStore
    /// Maps' icon, looked up once.
    private lazy var mapsApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Maps")

    init(store: QuicklinksStore) {
        self.store = store
    }

    /// Longer than this, the typed text is cut short in a row's title.
    static let titleLimit = 48

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        let enabled = store.fallbackEntries.filter(\.enabled)
        return enabled.enumerated().compactMap { index, entry in
            item(entry.id, text: query.text, score: 1 - Double(index) * 0.01)
        }
    }

    private func item(_ id: String, text: String, score: Double) -> LauncherItem? {
        let shown = text.count > Self.titleLimit ? String(text.prefix(Self.titleLimit - 1)) + "…" : text
        let quoted = "“\(shown)”"
        let title: String
        let icon: LauncherIcon
        let action: LauncherAction
        switch id {
        case "google", "duckduckgo", "maps":
            guard let url = QuicklinksFallbacks.searchURL(id, query: text) else { return nil }
            let name = id == "google" ? "Google" : id == "duckduckgo" ? "DuckDuckGo" : "Maps"
            title = "Search \(name) for \(quoted)"
            if id == "maps" {
                icon = mapsApp.map { .file($0) } ?? .symbol("map")
            } else {
                let host = id == "google" ? "www.google.com" : "duckduckgo.com"
                icon = store.favicons.image(for: host).map { .image($0) } ?? .symbol("magnifyingglass")
            }
            action = LauncherAction(id: "open", title: "Search \(name)", symbol: "magnifyingglass") { context in
                if !NSWorkspace.shared.open(url) {
                    log("fallback: nothing opens \(url.scheme ?? "the link")")
                    context.show()
                    context.flash("No app opens \(name) links")
                }
            }
        case "ai":
            title = "Ask AI \(quoted)"
            icon = .symbol("sparkles")
            action = LauncherAction(id: "ask", title: "Ask AI", symbol: "sparkles", keepsPanelOpen: true) { context in
                QuickAIFeature.ask(text, context: context)
            }
        case "files":
            title = "Search Files for \(quoted)"
            icon = .symbol("doc.text.magnifyingglass")
            action = LauncherAction(id: "search", title: "Search in DigUp's Window", symbol: "macwindow") { context in
                context.app.showSearchWindow(query: text)
            }
        default:
            guard id.hasPrefix(QuicklinksFallbacks.quicklinkPrefix),
                  let record = store.record(id: String(id.dropFirst(QuicklinksFallbacks.quicklinkPrefix.count))),
                  let key = QuicklinksItems.typedKey(store.template(for: record)) else { return nil }
            let template = store.template(for: record)
            let prompt = QuicklinkTemplate.prompt(for: template.arguments[0], quicklinkName: record.name)
            title = template.arguments[0].label == nil
                ? prompt.replacingOccurrences(of: "…", with: "") + " for \(quoted)"
                : "\(record.name) \(quoted)"
            icon = store.icon(for: record)
            let store = self.store
            action = LauncherAction(id: "open", title: "Open \(record.name)", symbol: "arrow.up.forward.app") { context in
                if let problem = await store.open(record, arguments: [key: text]) {
                    context.show()
                    context.flash(problem)
                }
            }
        }
        return LauncherItem(id: "fb:\(id)", title: title, icon: icon, accessory: "Fallback", section: .fallback,
                            score: score, actions: [action], tracksUsage: false)
    }
}

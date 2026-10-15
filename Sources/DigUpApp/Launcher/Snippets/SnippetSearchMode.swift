import AppKit
import DigUpKit
import SwiftUI

/// Search Snippets: every snippet, pinned first, with a preview of what it pastes. ↩ pastes into the app you came
/// from, ⌘↩ copies, ⌘N creates a new one, ⌘E edits.
final class SnippetSearchMode: LauncherMode {
    let title = "Search Snippets"
    let placeholder = "Search snippets by name, keyword or text…"
    let icon: LauncherIcon = .symbol("text.quote")
    var keysHint: String? { "↩ Paste   ⌘↩ Copy   ⌘K Actions" }
    var statusHint: String? {
        let count = SnippetStore.shared.snippets.count
        return count == 1 ? "1 snippet" : "\(count) snippets"
    }

    private static let pinned = LauncherSection.named("Pinned", order: 0)
    private static let all = LauncherSection.named("Snippets", order: 1)
    private static let create = LauncherSection.named("New", order: 2)

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let store = SnippetStore.shared
        let preview = SnippetItems.previewValues()
        var items: [LauncherItem] = []
        if query.isEmpty {
            for snippet in store.sorted {
                items.append(SnippetItems.item(snippet, score: 0.5, section: snippet.pinned ? Self.pinned : Self.all,
                                               preview: preview))
            }
        } else {
            let matches = store.sorted
                .compactMap { snippet in SnippetLibrary.score(snippet, query: query.raw).map { (snippet, $0) } }
                .sorted { $0.1 > $1.1 }
            for (snippet, score) in matches {
                items.append(SnippetItems.item(snippet, score: score, section: Self.all, preview: preview))
            }
        }
        items.append(createItem(query))
        return items
    }

    /// ⌘N anywhere in the list creates a snippet.
    func handle(_ event: NSEvent, query: String, context: LauncherContext) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, event.charactersIgnoringModifiers == "n" else { return false }
        context.hide()
        SnippetEditor.shared.open(nil)
        return true
    }

    /// "Create Snippet", last: what's typed becomes the new snippet's text.
    private func createItem(_ query: LauncherQuery) -> LauncherItem {
        let text = query.text
        return LauncherItem(
            id: SnippetProvider.createID, title: "Create Snippet",
            subtitle: text.isEmpty ? "Save text to paste or expand with a keyword" : "With “\(text)”",
            icon: .symbol("plus.square.on.square"), accessory: "⌘N", section: Self.create, score: 0,
            actions: [
                LauncherAction(id: "create", title: "Create Snippet", symbol: "plus") { _ in
                    SnippetEditor.shared.open(nil, text: text)
                },
            ],
            tracksUsage: false)
    }
}

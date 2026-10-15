import AppKit
import DigUpKit
import SwiftUI

/// Snippets: saved text, pasted from the launcher or expanded as you type its keyword.
enum SnippetsFeature: LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [SnippetProvider()]
    }

    /// Loads the snippets, then starts text expansion when it's on (it follows every later change to the snippets or
    /// the settings).
    static func start(_ launcher: Launcher) {
        let store = SnippetStore.shared
        store.load()
        store.onChange.append { [weak launcher] in
            SnippetExpander.shared.update()
            // An open Search Snippets shows an edited, added or deleted snippet right away.
            guard let panel = launcher?.panel, panel.isVisible, panel.mode is SnippetSearchMode else { return }
            panel.refresh()
        }
        SnippetExpander.shared.update()
    }

    static var settingsTitle: String? { "Snippets" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(SnippetSettingsView(store: SnippetStore.shared, expander: SnippetExpander.shared))
    }
}

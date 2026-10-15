import AppKit
import DigUpKit
import SwiftUI

/// Quicklinks, fallback commands, per-item aliases/hotkeys/favorites, deeplinks (digup://) and the Hyper Key.
enum QuicklinksFeature: LauncherFeature {
    /// What the providers, the windows, the deeplinks and Settings share.
    static let store = QuicklinksStore()

    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [QuicklinksProvider(launcher: launcher, store: store), QuicklinksFallbackProvider(store: store)]
    }

    static func start(_ launcher: Launcher) {
        store.favicons.preload()
        QuicklinksHotkeys.shared.start(launcher: launcher, store: store)
        QuicklinksDeeplinks.shared.start(launcher: launcher, store: store)
        QuicklinksHyperKey.shared.start(store: store)
    }

    static var settingsTitle: String? { "Quicklinks & Shortcuts" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(QuicklinksSettingsView(launcher: launcher, store: store))
    }
}

/// Actions every item that `tracksUsage` gets in its action panel (⌘K), after its own: favorites, alias, hotkey.
enum Personalization {
    static func actions(for item: LauncherItem, context: LauncherContext) -> [LauncherAction] {
        let id = item.id
        let usage = context.launcher.usage
        var actions: [LauncherAction] = []

        let isFavorite = usage.favorites.contains(id)
        actions.append(LauncherAction(id: "personal.favorite", title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                      symbol: isFavorite ? "star.slash" : "star",
                                      shortcut: LauncherShortcut("f", [.command, .shift]), keepsPanelOpen: true) { context in
            let adding = !context.launcher.usage.favorites.contains(id)
            context.launcher.personalize { $0.toggleFavorite(id) }
            context.flash(adding ? "Added to Favorites" : "Removed from Favorites")
            context.refresh()
        })
        if let index = usage.favorites.firstIndex(of: id) {
            if index > 0 {
                actions.append(moveFavorite(id, by: -1, title: "Move Up in Favorites", symbol: "arrow.up", key: "up"))
            }
            if index < usage.favorites.count - 1 {
                actions.append(moveFavorite(id, by: 1, title: "Move Down in Favorites", symbol: "arrow.down", key: "down"))
            }
        }

        let alias = usage.aliases[id]
        actions.append(LauncherAction(id: "personal.alias", title: alias == nil ? "Set Alias…" : "Edit Alias…",
                                      symbol: "character.cursor.ibeam", keepsPanelOpen: true) { context in
            await setAlias(for: item, context: context)
        })
        if let alias {
            actions.append(LauncherAction(id: "personal.alias.remove", title: "Remove Alias “\(alias)”",
                                          symbol: "delete.left", keepsPanelOpen: true) { context in
                context.launcher.personalize { QuicklinksPersonalization.setAlias(nil, for: id, in: &$0) }
                context.flash("Removed the alias")
                context.refresh()
            })
        }

        let hotkey = usage.hotkeys[id].flatMap { KeyCombo($0) }
        actions.append(LauncherAction(id: "personal.hotkey", title: hotkey == nil ? "Set Hotkey…" : "Change Hotkey…",
                                      symbol: "command", keepsPanelOpen: true) { context in
            let back = QuicklinksReturn.root.whenDone(context)
            QuicklinksHotkeyRecorder.show(for: item, launcher: context.launcher, app: context.app, done: back)
        })
        if let hotkey {
            actions.append(LauncherAction(id: "personal.hotkey.remove", title: "Remove Hotkey \(hotkey.display)",
                                          symbol: "delete.left", keepsPanelOpen: true) { context in
                context.launcher.personalize { QuicklinksPersonalization.setHotkey(nil, for: id, in: &$0) }
                context.flash("Removed the hotkey")
                context.refresh()
            })
        }

        actions.append(LauncherAction(id: "personal.deeplink", title: "Copy Deeplink", symbol: "link.circle",
                                      shortcut: LauncherShortcut("c", [.command, .option]), keepsPanelOpen: true) { context in
            context.copy(QuicklinksDeeplink.run(itemID: id).url.absoluteString, flash: "Copied the deeplink")
        })

        if QuicklinksPersonalization.hasRanking(id, in: usage) {
            actions.append(LauncherAction(id: "personal.ranking", title: "Reset Ranking", symbol: "arrow.counterclockwise",
                                          keepsPanelOpen: true) { context in
                context.launcher.personalize { QuicklinksPersonalization.resetRanking(id, in: &$0) }
                context.flash("It ranks as if never used")
                context.refresh()
            })
        }
        return actions
    }

    private static func moveFavorite(_ id: String, by offset: Int, title: String, symbol: String,
                                     key: String) -> LauncherAction {
        LauncherAction(id: "personal.favorite.\(key)", title: title, symbol: symbol,
                       shortcut: LauncherShortcut(key, [.command, .option]), keepsPanelOpen: true) { context in
            var moved = false
            context.launcher.personalize { moved = QuicklinksPersonalization.moveFavorite(id, by: offset, in: &$0) }
            if moved { context.refresh() }
        }
    }

    /// Asks for the alias; one that another item has moves here if you say so.
    private static func setAlias(for item: LauncherItem, context: LauncherContext) async {
        let launcher = context.launcher
        let back = QuicklinksReturn.root.whenDone(context)
        defer { back() }
        let current = launcher.usage.aliases[item.id] ?? ""
        guard let typed = context.prompt("Alias for “\(item.title)”",
                                         message: "Type it in the launcher and ↩ runs this, whatever else matches."
                                             + (item.id.hasPrefix("ql:") ? " For a quicklink, what follows the alias "
                                                 + "and a space is what it searches for." : ""),
                                         initial: current, button: "Save") else { return }
        guard let alias = QuicklinksPersonalization.normalizedAlias(typed) else {
            if !current.isEmpty {
                launcher.personalize { QuicklinksPersonalization.setAlias(nil, for: item.id, in: &$0) }
            }
            return
        }
        if let owner = QuicklinksPersonalization.aliasOwner(alias, in: launcher.usage, except: item.id) {
            let ownerTitle = await launcher.item(id: owner)?.title
            guard context.confirm("“\(alias)” is the alias of \(ownerTitle.map { "“\($0)”" } ?? "another item")",
                                  message: "Move it to “\(item.title)”?", button: "Move Alias") else { return }
        }
        launcher.personalize { QuicklinksPersonalization.setAlias(alias, for: item.id, in: &$0) }
        log("quicklinks: set an alias")
        DispatchQueue.main.async { context.flash("Alias “\(alias)” saved") }
    }
}

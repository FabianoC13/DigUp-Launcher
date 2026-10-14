import AppKit
import DigUpKit

extension WindowsFeature {
    /// A menu command of the app in front, from its menu bar.
    nonisolated struct MenuEntry: Sendable {
        let element: Element
        let title: String
        /// The menus above it ("File", "Export").
        let path: [String]
        /// "⇧⌘S", as the menu shows it.
        let shortcut: String?
        /// Its place in the walk: the menu bar's order.
        let index: Int
    }

    /// What reading an app's menu bar found.
    nonisolated struct MenuWalk: Sendable {
        var entries: [MenuEntry] = []
        /// The app has a menu bar Accessibility can read.
        var readable = true
        /// It stopped at `menuWalkLimit` (a huge menu bar): the rest isn't listed.
        var truncated = false
    }

    /// How long reading one app's menus may take.
    nonisolated static let menuWalkLimit: TimeInterval = 1.5

    /// Search Menu Items: every enabled command in the menus of the app you came from, with where it is and its
    /// shortcut. ↩ brings the app back and runs it.
    final class MenuItemsMode: LauncherMode {
        let title: String
        let placeholder: String
        let icon: LauncherIcon
        private let app: NSRunningApplication
        private let appName: String
        private let load: Task<MenuWalk, Never>
        private var walk: MenuWalk?

        init(app: NSRunningApplication) {
            self.app = app
            appName = app.localizedName ?? "the app"
            title = "Menu Items"
            placeholder = "Search \(appName)’s menus…"
            icon = app.icon.map { .image($0) } ?? app.bundleURL.map { .file($0) } ?? .symbol("filemenu.and.selection")
            let pid = app.processIdentifier
            load = Task.detached(priority: .userInitiated) {
                let started = Date()
                let walk = WindowsFeature.walkMenus(pid: pid)
                log("windows: read \(walk.entries.count) menu items in \(ms(since: started))"
                    + (walk.truncated ? " (stopped at the time limit)" : ""))
                return walk
            }
        }

        func items(for query: LauncherQuery) async -> [LauncherItem] {
            let walk = await load.value
            guard !Task.isCancelled else { return [] }
            self.walk = walk
            if query.isEmpty {
                // In menu bar order, a section per menu.
                var sections: [String: LauncherSection] = [:]
                return walk.entries.map { entry in
                    let menu = entry.path.first ?? appName
                    let section = sections[menu] ?? LauncherSection.named(menu, order: sections.count)
                    sections[menu] = section
                    return item(entry, section: section, score: 1)
                }
            }
            let scored = walk.entries.compactMap { entry -> (MenuEntry, Double)? in
                guard let score = query.match(entry.title, keywords: [LauncherMenuPath.display(entry.path + [entry.title])])
                else { return nil }
                return (entry, score)
            }
            return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.index < $1.0.index }
                .map { item($0.0, section: .results, score: $0.1) }
        }

        var statusHint: String? {
            guard let walk else { return "Reading \(appName)’s menus…" }
            if !walk.readable { return "\(appName)’s menus can't be read" }
            let count = walk.entries.count == 1 ? "1 menu item" : "\(walk.entries.count) menu items"
            return walk.truncated ? "\(count) (the menus are too big to read in full)" : count
        }

        private func item(_ entry: MenuEntry, section: LauncherSection, score: Double) -> LauncherItem {
            let app = self.app, appName = self.appName, element = entry.element, title = entry.title
            let run = LauncherAction(id: "run", title: "Run Menu Item", symbol: "filemenu.and.selection",
                                     keepsPanelOpen: true) { context in
                // The command acts on the app's key window: the app comes forward first.
                await WindowsFeature.bringForward(app)
                context.hide()
                try? await Task.sleep(for: .milliseconds(60))
                let result = await Task.detached { AX.perform(element, kAXPressAction) }.value
                // A command that opens a modal dialog keeps the app busy past the timeout: that one did run.
                if result != .success && result != .cannotComplete {
                    log("windows: pressing \(appName)'s \"\(title)\" failed (\(result.rawValue))")
                    SystemHUD.show("“\(title)” couldn't be run", symbol: "exclamationmark.triangle")
                }
            }
            var metadata: [(label: String, value: String)] = [("Menu", LauncherMenuPath.display(entry.path))]
            if let shortcut = entry.shortcut { metadata.append(("Shortcut", shortcut)) }
            return LauncherItem(id: "\(WindowsFeature.prefix):menu-item/\(entry.index)", title: title,
                                subtitle: LauncherMenuPath.display(entry.path), icon: icon, accessory: entry.shortcut,
                                section: section, score: score, actions: [run], metadata: metadata,
                                tracksUsage: false)
        }
    }

    /// Walks an app's menu bar (not the Apple menu) for its enabled commands, at most `menuWalkLimit` seconds and
    /// four submenus deep. Each item's attributes come in one message.
    nonisolated static func walkMenus(pid: pid_t) -> MenuWalk {
        var walk = MenuWalk()
        guard let bar = AX.element(AX.application(pid), kAXMenuBarAttribute) else {
            walk.readable = false
            return walk
        }
        let deadline = Date().addingTimeInterval(menuWalkLimit)
        let attributes = [kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute, kAXMenuItemCmdCharAttribute,
                          kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdGlyphAttribute]

        func visit(_ menu: Element, path: [String], depth: Int) {
            for (index, item) in AX.elements(menu, kAXChildrenAttribute).enumerated() {
                guard Date() < deadline else {
                    walk.truncated = true
                    return
                }
                let values = AX.values(item, attributes)
                let title = ((values[0] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { continue }   // separators, the Help menu's search field
                guard (values[1] as? NSNumber)?.boolValue ?? true else { continue }
                if let submenu = AX.elements(in: values[2]).first {
                    if LauncherMenuPath.shouldWalk(menuIndex: index, depth: depth) {
                        visit(submenu, path: path + [title], depth: depth + 1)
                    }
                    continue
                }
                let shortcut = LauncherMenuShortcut.display(character: values[3] as? String,
                                                            modifiers: (values[4] as? NSNumber)?.intValue,
                                                            glyph: (values[5] as? NSNumber)?.intValue)
                walk.entries.append(MenuEntry(element: item, title: title, path: path, shortcut: shortcut,
                                              index: walk.entries.count))
            }
        }

        for (index, barItem) in AX.elements(bar, kAXChildrenAttribute).enumerated() {
            guard Date() < deadline else {
                walk.truncated = true
                break
            }
            guard LauncherMenuPath.shouldWalk(menuIndex: index, depth: 0) else { continue }
            let title = (AX.string(barItem, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, let menu = AX.elements(barItem, kAXChildrenAttribute).first else { continue }
            visit(menu, path: [title], depth: 1)
        }
        return walk
    }
}

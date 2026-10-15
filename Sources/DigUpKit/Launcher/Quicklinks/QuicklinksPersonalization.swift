import Foundation

/// The edits behind the action panel's Favorites, Alias, Hotkey and Reset Ranking actions, on the launcher's
/// `LauncherUsage`. An alias or a hotkey belongs to one item at a time: giving it to another takes it away.
public enum QuicklinksPersonalization {
    /// Forgets how often and lately `id` ran and what it was picked for; its favorite, alias and hotkey stay.
    public static func resetRanking(_ id: String, in usage: inout LauncherUsage) {
        usage.records[id] = nil
        for key in usage.picks.keys { usage.picks[key]?[id] = nil }
        usage.picks = usage.picks.filter { !$0.value.isEmpty }
    }

    /// There's something to reset.
    public static func hasRanking(_ id: String, in usage: LauncherUsage) -> Bool {
        usage.records[id] != nil || usage.picks.values.contains { $0[id] != nil }
    }

    /// Moves a favorite up (negative) or down (positive), as far as the list goes. False when it didn't move.
    @discardableResult
    public static func moveFavorite(_ id: String, by offset: Int, in usage: inout LauncherUsage) -> Bool {
        guard let index = usage.favorites.firstIndex(of: id) else { return false }
        let target = max(0, min(usage.favorites.count - 1, index + offset))
        guard target != index else { return false }
        usage.favorites.remove(at: index)
        usage.favorites.insert(id, at: target)
        return true
    }

    /// An alias as it's saved and matched: lowercased, accents folded, single spaces. Nil when nothing's left.
    public static func normalizedAlias(_ text: String) -> String? {
        let alias = FuzzyMatch.normalize(text)
        return alias.isEmpty ? nil : alias
    }

    /// The item (other than `id`) whose alias this is.
    public static func aliasOwner(_ alias: String, in usage: LauncherUsage, except id: String? = nil) -> String? {
        guard let key = normalizedAlias(alias) else { return nil }
        return usage.aliases.first { $0.key != id && FuzzyMatch.normalize($0.value) == key }?.key
    }

    /// The item (other than `id`) with this hotkey spec ("cmd+opt+s").
    public static func hotkeyOwner(_ spec: String, in usage: LauncherUsage, except id: String? = nil) -> String? {
        usage.hotkeys.first { $0.key != id && $0.value == spec }?.key
    }

    /// Gives `id` this alias (nil or blank: removes its alias), taking it from any other item.
    public static func setAlias(_ alias: String?, for id: String, in usage: inout LauncherUsage) {
        guard let alias = alias.flatMap(normalizedAlias) else {
            usage.aliases[id] = nil
            return
        }
        while let owner = aliasOwner(alias, in: usage, except: id) { usage.aliases[owner] = nil }
        usage.aliases[id] = alias
    }

    /// Gives `id` this hotkey spec (nil: removes its hotkey), taking it from any other item.
    public static func setHotkey(_ spec: String?, for id: String, in usage: inout LauncherUsage) {
        guard let spec, !spec.isEmpty else {
            usage.hotkeys[id] = nil
            return
        }
        while let owner = hotkeyOwner(spec, in: usage, except: id) { usage.hotkeys[owner] = nil }
        usage.hotkeys[id] = spec
    }
}

/// One fallback command and whether it's on. Built-ins have plain ids ("google"); a quicklink that takes an argument
/// is "ql:<its id>".
public struct QuicklinksFallbackEntry: Codable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool

    public init(id: String, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }
}

/// The fallback commands' order and switches ("Search Google for …", "Ask AI", …): what's offered under every
/// search, with what was typed.
public enum QuicklinksFallbacks {
    /// The built-in fallbacks, in their first-run order (all on).
    public static let builtIns = ["google", "ai", "duckduckgo", "maps", "files"]
    public static let quicklinkPrefix = "ql:"

    /// The saved list made current: built-ins it lacks are added (on), quicklinks that take an argument and aren't
    /// listed are added (off), and entries for anything gone are dropped. Order is kept; duplicates go.
    public static func normalized(_ saved: [QuicklinksFallbackEntry], quicklinks: [String]) -> [QuicklinksFallbackEntry] {
        let known = Set(builtIns + quicklinks.map { quicklinkPrefix + $0 })
        var seen = Set<String>()
        var result: [QuicklinksFallbackEntry] = []
        for entry in saved where known.contains(entry.id) && seen.insert(entry.id).inserted {
            result.append(entry)
        }
        for id in builtIns where seen.insert(id).inserted {
            result.append(QuicklinksFallbackEntry(id: id, enabled: true))
        }
        for id in quicklinks.map({ quicklinkPrefix + $0 }) where seen.insert(id).inserted {
            result.append(QuicklinksFallbackEntry(id: id, enabled: false))
        }
        return result
    }

    /// A built-in's name in Settings ("Search Google").
    public static func title(of id: String) -> String? {
        switch id {
        case "google": "Search Google"
        case "ai": "Ask AI"
        case "duckduckgo": "Search DuckDuckGo"
        case "maps": "Search Maps"
        case "files": "Search Files"
        default: nil
        }
    }

    /// Where a built-in web fallback goes with `query` (nil for the others: Ask AI, Search Files).
    public static func searchURL(_ id: String, query: String) -> URL? {
        let text = QuicklinkTemplate.percentEncode(query)
        switch id {
        case "google": return URL(string: "https://www.google.com/search?q=\(text)")
        case "duckduckgo": return URL(string: "https://duckduckgo.com/?q=\(text)")
        case "maps": return URL(string: "maps://?q=\(text)")
        default: return nil
        }
    }

    /// Moves the entry at `index` up (negative) or down (positive), within the list.
    public static func move(_ entries: inout [QuicklinksFallbackEntry], at index: Int, by offset: Int) {
        guard entries.indices.contains(index) else { return }
        let target = max(0, min(entries.count - 1, index + offset))
        guard target != index else { return }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: target)
    }
}

/// The Quicklinks feature's own settings, saved next to the quicklinks: the fallback commands, the Hyper Key, and the
/// items that may run from a `digup://run` link without asking.
public struct QuicklinksSettings: Codable, Equatable, Sendable {
    /// What Caps Lock does when pressed and let go alone while it's the Hyper Key.
    public enum QuickPress: String, Codable, CaseIterable, Sendable {
        case nothing, escape
    }

    /// Order and switches; `QuicklinksFallbacks.normalized` brings it up to date.
    public var fallbacks: [QuicklinksFallbackEntry] = []
    /// Caps Lock acts as ⌃⌥⌘ (and ⇧ with `hyperIncludesShift`).
    public var hyperKeyEnabled = false
    public var hyperIncludesShift = true
    public var hyperQuickPress = QuickPress.nothing
    /// The HID usage Caps Lock was mapped to before the Hyper Key took it over, to put back when it's turned off.
    public var previousCapsLock: UInt64?
    /// Caps Lock → F18 is in place (DigUp put it there), so a launch after a crash knows to take it out.
    public var hyperMappingApplied = false
    /// Item ids a `digup://run` link may run without asking first.
    public var trustedDeeplinks: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case fallbacks, hyperKeyEnabled, hyperIncludesShift, hyperQuickPress, previousCapsLock, hyperMappingApplied
        case trustedDeeplinks
    }

    /// Older files may lack newer keys, and an unknown quick press reads as none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fallbacks = try container.decodeIfPresent([QuicklinksFallbackEntry].self, forKey: .fallbacks) ?? []
        hyperKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .hyperKeyEnabled) ?? false
        hyperIncludesShift = try container.decodeIfPresent(Bool.self, forKey: .hyperIncludesShift) ?? true
        hyperQuickPress = (try? container.decodeIfPresent(QuickPress.self, forKey: .hyperQuickPress)) ?? .nothing
        previousCapsLock = try container.decodeIfPresent(UInt64.self, forKey: .previousCapsLock)
        hyperMappingApplied = try container.decodeIfPresent(Bool.self, forKey: .hyperMappingApplied) ?? false
        trustedDeeplinks = try container.decodeIfPresent([String].self, forKey: .trustedDeeplinks) ?? []
    }
}

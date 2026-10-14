import Foundation

/// What the launcher learns from you, saved as JSON: how often and how lately each item ran (frecency), which item you
/// picked for what you typed, your favorites, aliases and per-item hotkeys.
///
/// Item ids are the launcher's ("app:/Applications/Safari.app", "cmd:lock-screen"). Pure data and arithmetic, so it
/// can be tested without the app; the app's `Launcher` owns one and saves it.
public struct LauncherUsage: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var count: Int
        public var last: Date

        public init(count: Int, last: Date) {
            self.count = count
            self.last = last
        }
    }

    /// Item id → how often and when it last ran.
    public var records: [String: Record] = [:]
    /// What was typed (normalized, up to `maxPickQuery` characters) → item id → how often it was picked for it.
    public var picks: [String: [String: Int]] = [:]
    /// Favorites, in the order they show with nothing typed.
    public var favorites: [String] = []
    /// Item id → alias ("ss" for Safari): typing the alias puts the item first.
    public var aliases: [String: String] = [:]
    /// Item id → hotkey spec ("cmd+opt+s"), registered system-wide.
    public var hotkeys: [String: String] = [:]

    public static let maxPickQuery = 24
    public static let halfLifeDays = 14.0

    public init() {}

    private enum CodingKeys: String, CodingKey { case records, picks, favorites, aliases, hotkeys }

    /// Older files may lack newer keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decodeIfPresent([String: Record].self, forKey: .records) ?? [:]
        picks = try container.decodeIfPresent([String: [String: Int]].self, forKey: .picks) ?? [:]
        favorites = try container.decodeIfPresent([String].self, forKey: .favorites) ?? []
        aliases = try container.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        hotkeys = try container.decodeIfPresent([String: String].self, forKey: .hotkeys) ?? [:]
    }

    /// `id` ran, after `query` was typed (nil: not from a search, e.g. a hotkey).
    public mutating func recordUse(_ id: String, query: String?, at date: Date = Date()) {
        var record = records[id] ?? Record(count: 0, last: date)
        record.count += 1
        record.last = date
        records[id] = record
        if let query {
            let key = Self.pickKey(query)
            if !key.isEmpty { picks[key, default: [:]][id, default: 0] += 1 }
        }
    }

    /// 0…1: used often and lately. Halves every `halfLifeDays` without use.
    public func frecency(_ id: String, now: Date = Date()) -> Double {
        guard let record = records[id] else { return 0 }
        let days = max(0, now.timeIntervalSince(record.last) / 86_400)
        let decay = pow(0.5, days / Self.halfLifeDays)
        return min(1, log2(1 + Double(record.count)) * decay / 5)
    }

    /// 0…1: how strongly `id` was picked for this exact query, or for a longer one that starts with it ("sa" when
    /// "saf" was typed before).
    public func pickBoost(_ id: String, query: String) -> Double {
        let key = Self.pickKey(query)
        guard !key.isEmpty else { return 0 }
        if let count = picks[key]?[id], count > 0 { return min(1, 0.6 + 0.1 * Double(count)) }
        var best = 0.0
        for (typed, counts) in picks where typed.hasPrefix(key) {
            if let count = counts[id], count > 0 { best = max(best, min(0.5, 0.3 + 0.05 * Double(count))) }
        }
        return best
    }

    /// The ids used most (by frecency), best first, at most `limit`.
    public func recent(limit: Int, now: Date = Date()) -> [String] {
        let scored: [(id: String, score: Double)] = records.keys.map { (id: $0, score: frecency($0, now: now)) }
        let used = scored.filter { $0.score > 0.001 }
        let ranked = used.sorted { (a: (id: String, score: Double), b: (id: String, score: Double)) -> Bool in
            a.score != b.score ? a.score > b.score : a.id < b.id
        }
        return ranked.prefix(limit).map(\.id)
    }

    /// The item whose alias is exactly what was typed.
    public func item(forAlias query: String) -> String? {
        let key = FuzzyMatch.normalize(query)
        guard !key.isEmpty else { return nil }
        return aliases.first { FuzzyMatch.normalize($0.value) == key }?.key
    }

    public mutating func toggleFavorite(_ id: String) {
        if let index = favorites.firstIndex(of: id) { favorites.remove(at: index) } else { favorites.append(id) }
    }

    /// Forgets an item (it's gone, or you asked): its record, picks, favorite, alias and hotkey.
    public mutating func forget(_ id: String) {
        records[id] = nil
        for key in picks.keys { picks[key]?[id] = nil }
        picks = picks.filter { !$0.value.isEmpty }
        favorites.removeAll { $0 == id }
        aliases[id] = nil
        hotkeys[id] = nil
    }

    static func pickKey(_ query: String) -> String {
        String(FuzzyMatch.normalize(query).prefix(maxPickQuery))
    }
}

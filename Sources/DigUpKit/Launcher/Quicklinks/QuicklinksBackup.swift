import Foundation

/// Any JSON value, kept as it was read: the snippets file travels in a backup without this code knowing its shape.
public enum QuicklinksJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([QuicklinksJSON])
    case object([String: QuicklinksJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([QuicklinksJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: QuicklinksJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// `incoming` added to `existing` without replacing anything: an array gains the elements it lacks (an object
    /// with an "id" counts as there when an element has the same id), an object gains the keys it lacks and merges
    /// arrays it has under the same key. Returns the merge and how many elements were added.
    public static func merge(_ existing: QuicklinksJSON?, with incoming: QuicklinksJSON) -> (QuicklinksJSON, added: Int) {
        guard let existing else {
            if case .array(let elements) = incoming { return (incoming, elements.count) }
            return (incoming, 1)
        }
        switch (existing, incoming) {
        case (.array(var elements), .array(let more)):
            var added = 0
            for element in more where !elements.contains(where: { $0.sameEntry(as: element) }) {
                elements.append(element)
                added += 1
            }
            return (.array(elements), added)
        case (.object(var fields), .object(let more)):
            var added = 0
            for (key, value) in more {
                if let current = fields[key] {
                    if case .array = current, case .array = value {
                        let (merged, count) = merge(current, with: value)
                        fields[key] = merged
                        added += count
                    }
                } else {
                    fields[key] = value
                }
            }
            return (.object(fields), added)
        default:
            return (existing, 0)
        }
    }

    /// The same entry: equal, or objects with equal "id" fields.
    private func sameEntry(as other: QuicklinksJSON) -> Bool {
        if self == other { return true }
        if case .object(let a) = self, case .object(let b) = other, let id = a["id"], id != .null {
            return b["id"] == id
        }
        return false
    }
}

/// Settings → Launcher's export: favorites, aliases, hotkeys, quicklinks and the snippets file, as one JSON file.
/// Importing merges it into what's there (nothing is replaced).
public struct QuicklinksBackup: Codable, Equatable, Sendable {
    public static let formatName = "digup-launcher-backup"

    public var format: String
    public var version: Int
    public var exported: Date?
    public var favorites: [String]
    /// Item id → alias.
    public var aliases: [String: String]
    /// Item id → hotkey spec ("cmd+opt+s").
    public var hotkeys: [String: String]
    public var quicklinks: [QuicklinkRecord]
    /// The Snippets feature's file, as it was.
    public var snippets: QuicklinksJSON?

    public init(exported: Date? = nil, favorites: [String] = [], aliases: [String: String] = [:],
                hotkeys: [String: String] = [:], quicklinks: [QuicklinkRecord] = [], snippets: QuicklinksJSON? = nil) {
        format = Self.formatName
        version = 1
        self.exported = exported
        self.favorites = favorites
        self.aliases = aliases
        self.hotkeys = hotkeys
        self.quicklinks = quicklinks
        self.snippets = snippets
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, exported, favorites, aliases, hotkeys, quicklinks, snippets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        guard format == Self.formatName else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: container,
                                                   debugDescription: "Not a DigUp launcher backup")
        }
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exported = try container.decodeIfPresent(Date.self, forKey: .exported)
        favorites = try container.decodeIfPresent([String].self, forKey: .favorites) ?? []
        aliases = try container.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        hotkeys = try container.decodeIfPresent([String: String].self, forKey: .hotkeys) ?? [:]
        quicklinks = try container.decodeIfPresent([QuicklinkRecord].self, forKey: .quicklinks) ?? []
        snippets = try container.decodeIfPresent(QuicklinksJSON.self, forKey: .snippets)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A backup from a file: DigUp's own, or a plain array of quicklinks (Raycast's quicklink export).
    public static func read(_ data: Data) throws -> QuicklinksBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let links = try? decoder.decode([QuicklinkRecord].self, from: data) {
            return QuicklinksBackup(quicklinks: links)
        }
        return try decoder.decode(QuicklinksBackup.self, from: data)
    }

    /// What an import added and what it left out.
    public struct Summary: Equatable, Sendable {
        public var quicklinksAdded = 0
        /// Already there: the same id, or the same name and link.
        public var quicklinksSkipped = 0
        public var favoritesAdded = 0
        public var aliasesAdded = 0
        /// The item had one already, or another item has that alias.
        public var aliasesSkipped = 0
        public var hotkeysAdded = 0
        public var hotkeysSkipped = 0
        public var snippetsAdded = 0

        public init() {}
    }

    /// Adds the backup's quicklinks to `quicklinks`, keeping what's there. A keyword another quicklink already has is
    /// dropped from the imported one.
    public func mergeQuicklinks(into quicklinks: inout [QuicklinkRecord], summary: inout Summary) {
        for var link in self.quicklinks {
            let duplicate = quicklinks.contains { existing in
                existing.id == link.id
                    || (existing.link.trimmingCharacters(in: .whitespaces) == link.link.trimmingCharacters(in: .whitespaces)
                        && existing.name.lowercased() == link.name.lowercased())
            }
            if duplicate {
                summary.quicklinksSkipped += 1
                continue
            }
            if let keyword = link.keyword.map(FuzzyMatch.normalize),
               quicklinks.contains(where: { $0.keyword.map(FuzzyMatch.normalize) == keyword }) {
                link.keyword = nil
            }
            quicklinks.append(link)
            summary.quicklinksAdded += 1
        }
    }

    /// Adds the backup's favorites, aliases and hotkeys to `usage`, keeping what's there: an item keeps its own alias
    /// or hotkey, and one already taken by another item isn't given out again.
    public func mergeUsage(into usage: inout LauncherUsage, summary: inout Summary) {
        for id in favorites where !usage.favorites.contains(id) {
            usage.favorites.append(id)
            summary.favoritesAdded += 1
        }
        for (id, alias) in aliases.sorted(by: { $0.key < $1.key }) {
            guard usage.aliases[id] == nil, let alias = QuicklinksPersonalization.normalizedAlias(alias),
                  QuicklinksPersonalization.aliasOwner(alias, in: usage) == nil else {
                summary.aliasesSkipped += 1
                continue
            }
            usage.aliases[id] = alias
            summary.aliasesAdded += 1
        }
        for (id, spec) in hotkeys.sorted(by: { $0.key < $1.key }) {
            guard usage.hotkeys[id] == nil, !spec.isEmpty,
                  QuicklinksPersonalization.hotkeyOwner(spec, in: usage) == nil else {
                summary.hotkeysSkipped += 1
                continue
            }
            usage.hotkeys[id] = spec
            summary.hotkeysAdded += 1
        }
    }
}

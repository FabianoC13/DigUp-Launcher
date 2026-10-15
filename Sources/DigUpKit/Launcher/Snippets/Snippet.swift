import Foundation

/// A saved piece of text: pasted from the launcher, or typed out wherever you type its keyword. The text can hold
/// dynamic placeholders ({date}, {clipboard}, {cursor}…: `SnippetPlaceholders`).
public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    /// A UUID: launcher item ids, favorites and hotkeys keep it.
    public var id: String
    public var name: String
    public var text: String
    /// Typing it anywhere expands the snippet (";sig", "!addr"); nil for none.
    public var keyword: String?
    public var tags: [String]
    /// Pinned snippets come first in Search Snippets.
    public var pinned: Bool
    public var created: Date
    public var modified: Date

    public init(id: String = UUID().uuidString, name: String, text: String, keyword: String? = nil,
                tags: [String] = [], pinned: Bool = false, created: Date = Date(), modified: Date? = nil) {
        self.id = id
        self.name = name
        self.text = text
        self.keyword = keyword.flatMap { $0.isEmpty ? nil : $0 }
        self.tags = tags
        self.pinned = pinned
        self.created = created
        self.modified = modified ?? created
    }

    private enum CodingKeys: String, CodingKey { case id, name, text, keyword, tags, pinned, created, modified }

    /// Older files may lack newer keys; a snippet without an id gets one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        keyword = try container.decodeIfPresent(String.self, forKey: .keyword).flatMap { $0.isEmpty ? nil : $0 }
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        created = try container.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try container.decodeIfPresent(Date.self, forKey: .modified) ?? created
    }
}

/// What can be done with a list of snippets without the app: check a keyword, search, duplicate, import and export.
public enum SnippetLibrary {
    /// Raycast's limit on a snippet's text.
    public static let maxTextLength = 65_536

    /// Why `keyword` can't be used, or nil when it can: it may not hold spaces, quotes or backticks, and two snippets
    /// can't share one (`id` is the snippet being edited).
    public static func keywordProblem(_ keyword: String, id: String?, in snippets: [Snippet]) -> String? {
        if keyword.isEmpty { return nil }
        if keyword.contains(where: { $0.isWhitespace || $0.isNewline }) { return "A keyword can't contain spaces." }
        if keyword.contains(where: { "\"'`".contains($0) }) { return "A keyword can't contain quotes or backticks." }
        if let other = snippets.first(where: { $0.id != id && $0.keyword == keyword }) {
            return "“\(other.name)” already uses this keyword."
        }
        return nil
    }

    /// A name for a snippet that has none: its first line, shortened.
    public static func defaultName(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > 40 else { return line.isEmpty ? "Untitled Snippet" : line }
        return String(line.prefix(39)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// How well a search matches a snippet: its name, keyword and tags fuzzily, its text by words. Nil for no match.
    public static func score(_ snippet: Snippet, query: String) -> Double? {
        let normalized = FuzzyMatch.normalize(query)
        guard !normalized.isEmpty else { return nil }
        var best = FuzzyMatch.best(query, name: snippet.name, keywords: snippet.tags)
        if let keyword = snippet.keyword {
            let folded = FuzzyMatch.normalize(keyword)
            if folded == normalized { best = max(best ?? 0, 0.98) }
            else if folded.hasPrefix(normalized) { best = max(best ?? 0, 0.85) }
        }
        if best == nil {
            let text = FuzzyMatch.normalize(snippet.text)
            if normalized.split(separator: " ").allSatisfy({ text.contains($0) }) { best = 0.45 }
        }
        return best
    }

    /// A copy of `snippet` named "… Copy" (or "… Copy 2"), without its keyword (keywords are unique).
    public static func duplicate(_ snippet: Snippet, in snippets: [Snippet], now: Date = Date()) -> Snippet {
        let names = Set(snippets.map(\.name))
        var name = "\(snippet.name) Copy"
        var number = 2
        while names.contains(name) {
            name = "\(snippet.name) Copy \(number)"
            number += 1
        }
        return Snippet(name: name, text: snippet.text, keyword: nil, tags: snippet.tags, created: now)
    }

    // MARK: Import and export

    /// What an import did.
    public struct Imported: Equatable, Sendable {
        public var snippets: [Snippet]
        public var added: Int
        /// Already there with the same name, text and keyword.
        public var duplicates: Int
        /// Added without their keyword, because another snippet has it (or it isn't a valid keyword).
        public var keywordsDropped: Int
    }

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case notSnippets

        public var description: String {
            "This file isn't a list of snippets: it should be a JSON array of {\"name\", \"text\", \"keyword\"}."
        }
    }

    /// Adds the snippets in a JSON export to `existing`: Raycast's format (an array of `{name, text, keyword}`), this
    /// app's own, or an object with a "snippets" array. "content", "snippet" and "phrase" are read as the text, "title"
    /// as the name, "abbreviation" and "trigger" as the keyword. Duplicates are skipped.
    public static func importing(_ data: Data, into existing: [Snippet], now: Date = Date()) throws -> Imported {
        let json = try? JSONSerialization.jsonObject(with: data)
        let list: [Any]
        if let array = json as? [Any] {
            list = array
        } else if let object = json as? [String: Any], let array = object["snippets"] as? [Any] {
            list = array
        } else {
            throw ImportError.notSnippets
        }
        func string(_ object: [String: Any], _ keys: [String]) -> String? {
            for key in keys {
                if let value = object[key] as? String { return value }
            }
            return nil
        }
        var result = Imported(snippets: existing, added: 0, duplicates: 0, keywordsDropped: 0)
        var found = 0
        for case let object as [String: Any] in list {
            guard let text = string(object, ["text", "content", "snippet", "phrase"]), !text.isEmpty else { continue }
            found += 1
            let name = string(object, ["name", "title", "label"]).flatMap { $0.isEmpty ? nil : $0 }
                ?? defaultName(for: text)
            var keyword = string(object, ["keyword", "abbreviation", "trigger"]).flatMap { $0.isEmpty ? nil : $0 }
            let tags = (object["tags"] as? [String]) ?? []
            if result.snippets.contains(where: { $0.name == name && $0.text == text && $0.keyword == keyword }) {
                result.duplicates += 1
                continue
            }
            if let typed = keyword, keywordProblem(typed, id: nil, in: result.snippets) != nil {
                keyword = nil
                result.keywordsDropped += 1
            }
            result.snippets.append(Snippet(name: name, text: String(text.prefix(maxTextLength)), keyword: keyword,
                                           tags: tags, created: now))
            result.added += 1
        }
        if found == 0, !list.isEmpty { throw ImportError.notSnippets }
        return result
    }

    /// Raycast's export format: a JSON array of `{name, text, keyword}` (no keyword key when there is none).
    public static func exportData(_ snippets: [Snippet]) throws -> Data {
        struct Exported: Encodable {
            let name: String
            let text: String
            let keyword: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snippets.map { Exported(name: $0.name, text: $0.text, keyword: $0.keyword) })
    }
}

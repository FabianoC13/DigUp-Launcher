import Foundation

/// A quicklink: a name for a link that the launcher opens. The link is a web address, a search URL with `{query}` in
/// it, a file or folder path, or another app's own URL ("slack://open"), and it can name the app it opens in.
///
/// Saved as JSON in the launcher's Quicklinks folder; also what Raycast's quicklink export reads as
/// (`{name, link, openWith?}`), so its files import.
public struct QuicklinkRecord: Codable, Equatable, Identifiable, Sendable {
    /// Stable across launches: favorites, aliases and hotkeys keep it ("ql:<id>").
    public var id: String
    public var name: String
    public var link: String
    /// The bundle id of the app it opens in; nil for the link's default app.
    public var openWith: String?
    /// Typed alone, or before what to search for ("g cats"), it picks this quicklink.
    public var keyword: String?

    public init(id: String = UUID().uuidString, name: String, link: String, openWith: String? = nil,
                keyword: String? = nil) {
        self.id = id
        self.name = name
        self.link = link
        self.openWith = openWith.flatMap(Self.nonEmpty)
        self.keyword = keyword.flatMap(Self.nonEmpty)
    }

    private enum CodingKeys: String, CodingKey { case id, name, title, link, url, openWith, keyword }

    /// Lenient, for files from elsewhere: a missing id gets a new one, "title"/"url" stand in for "name"/"link", and
    /// empty optional fields read as none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decode(String.self, forKey: .title)
        let link = try container.decodeIfPresent(String.self, forKey: .link)
            ?? container.decode(String.self, forKey: .url)
        self.init(id: try container.decodeIfPresent(String.self, forKey: .id).flatMap(Self.nonEmpty) ?? UUID().uuidString,
                  name: name, link: link,
                  openWith: try container.decodeIfPresent(String.self, forKey: .openWith),
                  keyword: try container.decodeIfPresent(String.self, forKey: .keyword))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(link, forKey: .link)
        try container.encodeIfPresent(openWith, forKey: .openWith)
        try container.encodeIfPresent(keyword, forKey: .keyword)
    }

    /// The quicklinks a first launch starts with (you can delete them).
    public static func defaults(makeID: () -> String = { UUID().uuidString }) -> [QuicklinkRecord] {
        [
            QuicklinkRecord(id: makeID(), name: "Google Search", link: "https://www.google.com/search?q={query}",
                            keyword: "g"),
            QuicklinkRecord(id: makeID(), name: "YouTube",
                            link: "https://www.youtube.com/results?search_query={query}", keyword: "yt"),
            QuicklinkRecord(id: makeID(), name: "GitHub", link: "https://github.com/search?q={query}", keyword: "gh"),
            QuicklinkRecord(id: makeID(), name: "Wikipedia", link: "https://en.wikipedia.org/w/index.php?search={query}",
                            keyword: "wiki"),
            QuicklinkRecord(id: makeID(), name: "Google Maps", link: "https://www.google.com/maps/search/{query}",
                            keyword: "gm"),
            QuicklinkRecord(id: makeID(), name: "Google Translate", link: "https://translate.google.com/?text={query}",
                            keyword: "gt"),
        ]
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Which quicklink a root search means, and what to search for with it: "google cats" is Google Search with "cats",
/// "g cats" too when "g" is its keyword, and "goo" is Google Search waiting for its argument.
public enum QuicklinkMatcher {
    public struct Match: Equatable, Sendable {
        /// 0…1, like `FuzzyMatch`.
        public let score: Double
        /// What was typed after the quicklink's name or keyword; nil when the whole query named it.
        public let argument: String?
    }

    /// A word naming a quicklink needs this many letters before what follows counts as its argument ("g cats" only
    /// works through a keyword).
    static let minimumHead = 2

    /// The best reading of `query` for a quicklink, or nil when it doesn't name it. A quicklink that takes no argument
    /// only matches the whole query.
    public static func match(_ query: String, name: String, keyword: String?, takesArgument: Bool) -> Match? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let keywords = keyword.map { [$0] } ?? []
        var best = FuzzyMatch.best(text, name: name, keywords: keywords).map { Match(score: $0, argument: nil) }
        guard takesArgument else { return best }
        let normalizedName = FuzzyMatch.normalize(name)
        let normalizedKeyword = keyword.map(FuzzyMatch.normalize)
        for (head, tail) in splits(text) {
            let key = FuzzyMatch.normalize(head)
            var score: Double?
            if let normalizedKeyword, !normalizedKeyword.isEmpty, key == normalizedKeyword {
                score = 0.98
            } else if key.count >= minimumHead, normalizedName.hasPrefix(key) {
                score = 0.9 + 0.08 * Double(key.count) / Double(max(normalizedName.count, 1))
            }
            guard let score else { continue }
            if best.map({ score > $0.score }) ?? true { best = Match(score: score, argument: tail) }
        }
        return best
    }

    /// Every way to cut `text` at a run of spaces into a head and a non-empty tail, shortest head first.
    static func splits(_ text: String) -> [(head: String, tail: String)] {
        var result: [(String, String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let head = String(text[..<index])
            var end = index
            while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
            let tail = String(text[end...])
            if !head.isEmpty, !tail.isEmpty { result.append((head, tail)) }
            index = end
        }
        return result
    }
}

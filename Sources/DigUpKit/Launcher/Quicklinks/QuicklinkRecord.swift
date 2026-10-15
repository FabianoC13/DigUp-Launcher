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

extension QuicklinkRecord {
    /// Ready-made quicklinks the editor offers ("From Library"): web searches and a few local places. Each gets a
    /// new id when it's added.
    public static let library: [QuicklinkRecord] = [
        QuicklinkRecord(id: "library-google", name: "Google Search", link: "https://www.google.com/search?q={query}",
                        keyword: "g"),
        QuicklinkRecord(id: "library-google-images", name: "Google Images",
                        link: "https://www.google.com/search?tbm=isch&q={query}", keyword: "gi"),
        QuicklinkRecord(id: "library-duckduckgo", name: "DuckDuckGo", link: "https://duckduckgo.com/?q={query}",
                        keyword: "ddg"),
        QuicklinkRecord(id: "library-youtube", name: "YouTube",
                        link: "https://www.youtube.com/results?search_query={query}", keyword: "yt"),
        QuicklinkRecord(id: "library-wikipedia", name: "Wikipedia",
                        link: "https://en.wikipedia.org/w/index.php?search={query}", keyword: "wiki"),
        QuicklinkRecord(id: "library-github", name: "GitHub", link: "https://github.com/search?q={query}",
                        keyword: "gh"),
        QuicklinkRecord(id: "library-stackoverflow", name: "Stack Overflow",
                        link: "https://stackoverflow.com/search?q={query}", keyword: "so"),
        QuicklinkRecord(id: "library-mdn", name: "MDN Web Docs",
                        link: "https://developer.mozilla.org/search?q={query}", keyword: "mdn"),
        QuicklinkRecord(id: "library-apple-developer", name: "Apple Developer Documentation",
                        link: "https://developer.apple.com/search/?q={query}", keyword: "adoc"),
        QuicklinkRecord(id: "library-npm", name: "npm", link: "https://www.npmjs.com/search?q={query}"),
        QuicklinkRecord(id: "library-reddit", name: "Reddit", link: "https://www.reddit.com/search/?q={query}"),
        QuicklinkRecord(id: "library-x", name: "X", link: "https://x.com/search?q={query}"),
        QuicklinkRecord(id: "library-hacker-news", name: "Hacker News",
                        link: "https://hn.algolia.com/?q={query}", keyword: "hn"),
        QuicklinkRecord(id: "library-imdb", name: "IMDb", link: "https://www.imdb.com/find/?q={query}"),
        QuicklinkRecord(id: "library-wolfram", name: "Wolfram Alpha",
                        link: "https://www.wolframalpha.com/input?i={query}", keyword: "wa"),
        QuicklinkRecord(id: "library-maps", name: "Google Maps", link: "https://www.google.com/maps/search/{query}",
                        keyword: "gm"),
        QuicklinkRecord(id: "library-apple-maps", name: "Apple Maps", link: "maps://?q={query}"),
        QuicklinkRecord(id: "library-translate", name: "Google Translate",
                        link: #"https://translate.google.com/?sl=auto&tl={argument name="to" default="en"}&text={query}"#,
                        keyword: "gt"),
        QuicklinkRecord(id: "library-downloads", name: "Downloads", link: "~/Downloads"),
        QuicklinkRecord(id: "library-desktop", name: "Desktop", link: "~/Desktop"),
    ]

    /// Why `keyword` can't be this quicklink's (`id`), or nil when it can: it's one word, and no other quicklink has
    /// it. A blank keyword is none, which is fine.
    public static func keywordProblem(_ keyword: String, for id: String, among links: [QuicklinkRecord]) -> String? {
        let key = FuzzyMatch.normalize(keyword)
        guard !key.isEmpty else { return nil }
        if key.contains(" ") { return "A keyword is one word" }
        if let other = links.first(where: { $0.id != id && $0.keyword.map(FuzzyMatch.normalize) == key }) {
            return "“\(other.name)” has that keyword"
        }
        return nil
    }

    /// A name for a link pasted on its own ("github.com/apple" → "github.com"): its host without "www.", or a
    /// path's last part.
    public static func suggestedName(for link: String) -> String {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if QuicklinkTemplate.isPath(text) {
            return (text as NSString).lastPathComponent
        }
        if let url = QuicklinkTemplate.destination(text, home: "/"), var host = url.host, !host.isEmpty {
            if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
            return host
        }
        return ""
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
    /// A later word of the name ("maps" in "Google Maps") needs this many letters when only its start is typed.
    static let minimumLaterHead = 3

    /// The best reading of `query` for a quicklink, or nil when it doesn't name it. A quicklink that takes no argument
    /// only matches the whole query.
    ///
    /// What's typed before the argument ranks best as the keyword, then as whole words that start the name ("google
    /// cats"), whole words later in it ("maps cats" for Google Maps), and least as the start of a word ("goo cats"),
    /// which is as likely the start of something else.
    public static func match(_ query: String, name: String, keyword: String?, takesArgument: Bool) -> Match? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let keywords = keyword.map { [$0] } ?? []
        var best = FuzzyMatch.best(text, name: name, keywords: keywords).map { Match(score: $0, argument: nil) }
        guard takesArgument else { return best }
        let normalizedName = FuzzyMatch.normalize(name)
        let normalizedKeyword = keyword.map(FuzzyMatch.normalize)
        for (head, tail) in splits(text) {
            guard let score = headScore(FuzzyMatch.normalize(head), name: normalizedName, keyword: normalizedKeyword)
            else { continue }
            if best.map({ score > $0.score }) ?? true { best = Match(score: score, argument: tail) }
        }
        return best
    }

    /// How well `head` (normalized) names the quicklink, before an argument.
    static func headScore(_ head: String, name: String, keyword: String?) -> Double? {
        if let keyword, !keyword.isEmpty, head == keyword { return 0.98 }
        let fit = Double(head.count) / Double(max(name.count, 1))
        // Where the name's words start, and whether the head ends where a word does.
        var starts = [name.startIndex]
        for index in name.indices where name[index] == " " { starts.append(name.index(after: index)) }
        for (position, start) in starts.enumerated() {
            let rest = name[start...]
            guard rest.hasPrefix(head) else { continue }
            let end = rest.index(rest.startIndex, offsetBy: head.count)
            let wholeWords = end == rest.endIndex || rest[end] == " "
            let first = position == 0
            switch (first, wholeWords) {
            case (true, true): return 0.9 + 0.08 * fit
            case (false, true): return 0.8 + 0.08 * fit
            case (true, false) where head.count >= minimumHead: return 0.62 + 0.1 * fit
            case (false, false) where head.count >= minimumLaterHead: return 0.55 + 0.1 * fit
            default: continue
            }
        }
        return nil
    }

    /// What follows an alias and a space ("ss cats" with the alias "ss": "cats"); nil when the query doesn't start
    /// with the alias, or nothing follows it.
    public static func argument(after alias: String, in query: String) -> String? {
        let key = FuzzyMatch.normalize(alias)
        guard !key.isEmpty else { return nil }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return splits(text).first { FuzzyMatch.normalize($0.head) == key }?.tail
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

import Foundation

/// How well what you typed matches a name, the way a launcher ranks: "saf" → Safari, "vsc" → Visual Studio Code,
/// "set wi" → "Settings: Wi-Fi". Scores run from 0 (no match: nil) to 1 (the whole name).
///
/// Case and accents don't count ("cafe" finds "Café"). The ladder, best first: the whole name, a prefix of it, a prefix
/// of one of its words, its initials, every typed word a prefix of some word, a substring, then the letters in order.
public enum FuzzyMatch {
    /// What was typed, normalized once (every name it's scored against is normalized once too, in `prepare`).
    public struct Query: Sendable {
        public let normalized: String
        let characters: [Character]
        let words: [String]

        public init(_ text: String) {
            normalized = FuzzyMatch.normalize(text)
            characters = Array(normalized.filter { $0 != " " })
            words = FuzzyMatch.words(normalized)
        }

        public var isEmpty: Bool { normalized.isEmpty }
    }

    /// A name, normalized and split once. Names repeat on every keystroke (app names, command titles), so
    /// `prepare` keeps them.
    public struct Target: Sendable {
        let normalized: String
        let characters: [Character]
        let words: [String]
        let initials: String

        init(_ text: String) {
            normalized = FuzzyMatch.normalize(text)
            characters = Array(normalized)
            words = FuzzyMatch.words(normalized)
            initials = FuzzyMatch.normalize(String(FuzzyMatch.words(text, splittingCamelCase: true).compactMap(\.first)))
        }
    }

    /// `text` prepared for matching, from the cache when it was seen before.
    public static func prepare(_ text: String) -> Target {
        cache.target(text)
    }

    /// The score of `query` against `target`, or nil when it doesn't match at all.
    public static func score(_ query: String, _ target: String) -> Double? {
        score(Query(query), prepare(target))
    }

    public static func score(_ query: Query, _ target: Target) -> Double? {
        let q = query.normalized
        let t = target.normalized
        guard !q.isEmpty, !t.isEmpty else { return nil }
        if t == q { return 1 }
        let fit = Double(q.count) / Double(t.count)   // a longer part of the name matched ranks higher
        if t.hasPrefix(q) { return 0.9 + 0.08 * fit }
        if target.words.dropFirst().contains(where: { $0.hasPrefix(q) }) { return 0.8 + 0.08 * fit }
        if query.words.count == 1, q.count >= 2, target.initials.hasPrefix(q) {
            return 0.75 + 0.04 * Double(q.count) / Double(max(target.initials.count, 1))
        }
        if query.words.count > 1,
           query.words.allSatisfy({ word in target.words.contains { $0.hasPrefix(word) } }) {
            return 0.7 + 0.08 * fit
        }
        if t.contains(q) { return 0.6 + 0.08 * fit }
        if let spread = subsequenceSpread(query.characters, in: target.characters) {
            // The letters in order: tighter is better ("sfri" in "Safari" beats it in "System Information").
            return 0.3 + 0.2 * Double(query.characters.count) / Double(spread)
        }
        return nil
    }

    /// The best score of `query` against a name and its other names (keywords count a little less than the name).
    public static func best(_ query: String, name: String, keywords: [String] = []) -> Double? {
        best(Query(query), name: name, keywords: keywords)
    }

    public static func best(_ query: Query, name: String, keywords: [String] = []) -> Double? {
        var best = score(query, prepare(name))
        for keyword in keywords {
            if let found = score(query, prepare(keyword)).map({ $0 * 0.92 }), found > (best ?? 0) { best = found }
        }
        return best
    }

    private static let cache = TargetCache()

    /// Prepared names by their text; cleared when it grows past `limit` (names come and go: files, clipboard text).
    private final class TargetCache: @unchecked Sendable {
        private var targets: [String: Target] = [:]
        private let lock = NSLock()
        private let limit = 20_000

        func target(_ text: String) -> Target {
            lock.lock()
            if let found = targets[text] {
                lock.unlock()
                return found
            }
            lock.unlock()
            let made = Target(text)
            lock.lock()
            if targets.count >= limit { targets.removeAll(keepingCapacity: true) }
            targets[text] = made
            lock.unlock()
            return made
        }
    }

    /// Lowercased, accents folded, runs of whitespace as one space.
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Words split on spaces and punctuation ("Wi-Fi" → "wi", "fi"), and on camel case when asked ("VSCode" → "VS",
    /// "Code"; "iTerm" → "i", "Term").
    static func words(_ text: String, splittingCamelCase: Bool = false) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isLetter || character.isNumber {
                if splittingCamelCase, let previous, character.isUppercase, previous.isLowercase, !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
            previous = character
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// How many characters of `target` it takes to find `query`'s letters in order (the tightest window from the first
    /// match), or nil when they aren't all there.
    static func subsequenceSpread(_ query: String, in target: String) -> Int? {
        subsequenceSpread(Array(query.filter { $0 != " " }), in: Array(target))
    }

    static func subsequenceSpread(_ q: [Character], in t: [Character]) -> Int? {
        guard !q.isEmpty else { return nil }
        var best: Int?
        for start in t.indices where t[start] == q[0] {
            var index = 1
            var position = start + 1
            while index < q.count, position < t.count {
                if t[position] == q[index] { index += 1 }
                position += 1
            }
            if index == q.count {
                let spread = position - start
                if best == nil || spread < best! { best = spread }
                if spread == q.count { break }   // can't get tighter
            }
        }
        return best
    }
}

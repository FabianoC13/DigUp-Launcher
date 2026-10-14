import Foundation

/// How well what you typed matches a name, the way a launcher ranks: "saf" → Safari, "vsc" → Visual Studio Code,
/// "set wi" → "Settings: Wi-Fi". Scores run from 0 (no match: nil) to 1 (the whole name).
///
/// Case and accents don't count ("cafe" finds "Café"). The ladder, best first: the whole name, a prefix of it, a prefix
/// of one of its words, its initials, every typed word a prefix of some word, a substring, then the letters in order.
public enum FuzzyMatch {
    /// The score of `query` against `target`, or nil when it doesn't match at all.
    public static func score(_ query: String, _ target: String) -> Double? {
        let q = normalize(query)
        let t = normalize(target)
        guard !q.isEmpty, !t.isEmpty else { return nil }
        if t == q { return 1 }
        let fit = Double(q.count) / Double(t.count)   // a longer part of the name matched ranks higher
        if t.hasPrefix(q) { return 0.9 + 0.08 * fit }
        let targetWords = words(t)
        if targetWords.dropFirst().contains(where: { $0.hasPrefix(q) }) { return 0.8 + 0.08 * fit }
        let queryWords = words(q)
        if queryWords.count == 1, q.count >= 2 {
            let initials = String(words(target, splittingCamelCase: true).compactMap(\.first)).lowercased()
            let folded = normalize(initials)
            if folded.hasPrefix(q) { return 0.75 + 0.04 * Double(q.count) / Double(max(folded.count, 1)) }
        }
        if queryWords.count > 1, queryWords.allSatisfy({ word in targetWords.contains { $0.hasPrefix(word) } }) {
            return 0.7 + 0.08 * fit
        }
        if t.contains(q) { return 0.6 + 0.08 * fit }
        if let spread = subsequenceSpread(q, in: t) {
            // The letters in order: tighter is better ("sfri" in "Safari" beats it in "System Information").
            return 0.3 + 0.2 * Double(q.count) / Double(spread)
        }
        return nil
    }

    /// The best score of `query` against a name and its other names (keywords count a little less than the name).
    public static func best(_ query: String, name: String, keywords: [String] = []) -> Double? {
        var best = score(query, name)
        for keyword in keywords {
            if let found = score(query, keyword).map({ $0 * 0.92 }), found > (best ?? 0) { best = found }
        }
        return best
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
        let q = Array(query.filter { $0 != " " })
        let t = Array(target)
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
            }
        }
        return best
    }
}

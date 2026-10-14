import Foundation

/// What a rewrite changed, word by word, for showing the edits of "Fix Spelling and Grammar" and the other rewrite
/// commands: the text as runs that stayed, were added or were removed.
public enum AIWordDiff {
    public struct Run: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case same, added, removed }

        public var kind: Kind
        public var text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Diffs past this many words on either side are too slow to show while typing goes on; nil then.
    public static let tokenLimit = 6000

    /// The runs that turn `old` into `new`, adjacent runs of a kind merged. A removal comes before the addition that
    /// replaces it ("teh" then "the"). nil when either side is longer than `tokenLimit` words.
    public static func runs(from old: String, to new: String) -> [Run]? {
        let before = tokens(old)
        let after = tokens(new)
        guard before.count <= tokenLimit, after.count <= tokenLimit else { return nil }
        let difference = after.difference(from: before)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var runs: [Run] = []
        func add(_ kind: Run.Kind, _ text: String) {
            if let last = runs.indices.last, runs[last].kind == kind {
                runs[last].text += text
            } else {
                runs.append(Run(kind, text))
            }
        }
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                add(.removed, before[i])
                i += 1
            } else if j < after.count, inserted.contains(j) {
                add(.added, after[j])
                j += 1
            } else if i < before.count, j < after.count {
                add(.same, after[j])
                i += 1
                j += 1
            } else {
                break   // can't happen with a consistent difference
            }
        }
        return mergeSpaces(runs)
    }

    /// Whether anything changed at all.
    public static func changed(_ runs: [Run]) -> Bool {
        runs.contains { $0.kind != .same }
    }

    /// Words (letters, digits and the apostrophes inside them), runs of whitespace, and each other character alone.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsWord = false
        var currentIsSpace = false
        for character in text {
            let isWord = character.isLetter || character.isNumber
                || ((character == "'" || character == "’") && currentIsWord)
            let isSpace = character.isWhitespace
            if (isWord && currentIsWord) || (isSpace && currentIsSpace) {
                current.append(character)
                continue
            }
            if !current.isEmpty { tokens.append(current) }
            current = String(character)
            currentIsWord = isWord
            currentIsSpace = isSpace
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// A lone space between a removal and an addition reads better inside the change: "~~a b~~ c d" rather than
    /// "~~a~~ ~~b~~ c d" split by kept spaces.
    private static func mergeSpaces(_ runs: [Run]) -> [Run] {
        var merged: [Run] = []
        var index = 0
        while index < runs.count {
            let run = runs[index]
            if run.kind == .same, run.text.allSatisfy(\.isWhitespace), let previous = merged.last,
               previous.kind != .same, index + 1 < runs.count, runs[index + 1].kind == previous.kind {
                merged[merged.count - 1].text += run.text + runs[index + 1].text
                index += 2
                continue
            }
            if let last = merged.indices.last, merged[last].kind == run.kind {
                merged[last].text += run.text
            } else {
                merged.append(run)
            }
            index += 1
        }
        return merged
    }
}

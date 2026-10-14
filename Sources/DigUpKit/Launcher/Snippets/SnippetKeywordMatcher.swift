import Foundation

/// Watches what's typed for snippet keywords: a rolling buffer of the last characters, checked after each one.
///
/// The app feeds it typed text and backspaces, and resets it when the caret may have moved (a click, an arrow, a ⌘
/// shortcut, another app). What came before a reset counts as a word boundary: you can't know what's left of the caret.
public struct SnippetKeywordMatcher: Sendable {
    /// When a keyword expands.
    public enum Trigger: String, CaseIterable, Codable, Sendable {
        /// As soon as its last character is typed.
        case immediately
        /// When a space or punctuation follows it (which is typed back after the expansion).
        case afterDelimiter

        public var title: String {
            switch self {
            case .immediately: "As soon as the keyword is typed"
            case .afterDelimiter: "After a space or punctuation"
            }
        }
    }

    /// A keyword was just typed.
    public struct Match: Equatable, Sendable {
        public var keyword: String
        /// Characters to delete (backspaces) before pasting: the keyword, and the delimiter after it.
        public var deleteCount: Int
        /// The delimiter that triggered it, to type back after the expansion ("" when expanding immediately).
        public var delimiter: String

        public init(keyword: String, deleteCount: Int, delimiter: String) {
            self.keyword = keyword
            self.deleteCount = deleteCount
            self.delimiter = delimiter
        }
    }

    /// Longest first, so ";addr2" wins over ";addr".
    public private(set) var keywords: [String]
    public var trigger: Trigger
    /// Off: a keyword only expands as a word of its own ("x;sig" doesn't, " ;sig" does).
    public var expandWithinWords: Bool
    public private(set) var buffer = ""
    /// The buffer starts where typing started (after a reset), not in the middle of a word.
    private var boundaryAtStart = true
    private var capacity = 2

    public init(keywords: [String] = [], trigger: Trigger = .immediately, expandWithinWords: Bool = true) {
        self.keywords = []
        self.trigger = trigger
        self.expandWithinWords = expandWithinWords
        setKeywords(keywords)
    }

    public mutating func setKeywords(_ keywords: [String]) {
        self.keywords = Array(Set(keywords.filter { !$0.isEmpty })).sorted {
            $0.count != $1.count ? $0.count > $1.count : $0 < $1
        }
        // The longest keyword, the character before it (the boundary check) and a delimiter after it.
        capacity = (self.keywords.first?.count ?? 0) + 2
        trim()
    }

    /// Characters were typed; the keyword they complete, if any (the buffer then starts over).
    public mutating func typed(_ text: String) -> Match? {
        for character in text {
            if let match = typed(character) { return match }
        }
        return nil
    }

    private mutating func typed(_ character: Character) -> Match? {
        guard !keywords.isEmpty else { return nil }
        if character.isNewline || character == "\t" {
            reset()
            return nil
        }
        if trigger == .afterDelimiter, Self.isDelimiter(character), let keyword = keywordAtEnd() {
            reset()
            return Match(keyword: keyword, deleteCount: keyword.count + 1, delimiter: String(character))
        }
        buffer.append(character)
        trim()
        if trigger == .immediately, let keyword = keywordAtEnd() {
            reset()
            return Match(keyword: keyword, deleteCount: keyword.count, delimiter: "")
        }
        return nil
    }

    /// ⌫: the last character is gone.
    public mutating func deleteBackward() {
        guard !buffer.isEmpty else {
            // Deleting what was there before typing started: whatever is left of the caret now is unknown.
            boundaryAtStart = false
            return
        }
        buffer.removeLast()
    }

    /// The caret may have moved: start over.
    public mutating func reset() {
        buffer = ""
        boundaryAtStart = true
    }

    /// The longest keyword the buffer ends with, standing as a word of its own unless `expandWithinWords`.
    private func keywordAtEnd() -> String? {
        for keyword in keywords where buffer.hasSuffix(keyword) {
            if expandWithinWords { return keyword }
            let before = buffer.dropLast(keyword.count).last
            if let before {
                if before.isWhitespace || Self.isDelimiter(before) { return keyword }
            } else if boundaryAtStart {
                return keyword
            }
        }
        return nil
    }

    private mutating func trim() {
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
            boundaryAtStart = false
        }
    }

    /// A space, punctuation or a symbol: what ends a word.
    static func isDelimiter(_ character: Character) -> Bool {
        character == " " || character == "\u{00A0}" || character.isPunctuation || character.isSymbol
    }
}

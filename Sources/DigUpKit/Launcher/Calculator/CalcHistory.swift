import Foundation

/// One saved calculation.
public struct CalcHistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// What was typed ("20% of 50").
    public var question: String
    /// The answer as it was copied or pasted ("10").
    public var answer: String
    public var kind: CalcAnswerKind
    public var date: Date
    /// Pinned entries stay at the top, are never trimmed, and show a live answer (a countdown, today's rate).
    public var pinned: Bool

    public init(id: UUID = UUID(), question: String, answer: String, kind: CalcAnswerKind, date: Date,
                pinned: Bool = false) {
        self.id = id
        self.question = question
        self.answer = answer
        self.kind = kind
        self.date = date
        self.pinned = pinned
    }
}

/// Calculator History: the answers you copied or pasted, newest first, at most `limit` besides the pinned ones.
public struct CalcHistory: Codable, Sendable, Equatable {
    public static let limit = 200

    public private(set) var entries: [CalcHistoryEntry]

    public init(entries: [CalcHistoryEntry] = []) {
        self.entries = entries
    }

    /// Pinned first, then newest first.
    public var sorted: [CalcHistoryEntry] {
        entries.filter(\.pinned) + entries.filter { !$0.pinned }
    }

    /// Saves a calculation; asking the same question again moves it to the top with the new answer.
    public mutating func add(question: String, answer: String, kind: CalcAnswerKind, date: Date = Date()) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answer.isEmpty else { return }
        var pinned = false
        var id = UUID()
        if let index = entries.firstIndex(where: { $0.question.caseInsensitiveCompare(question) == .orderedSame }) {
            pinned = entries[index].pinned
            id = entries[index].id
            entries.remove(at: index)
        }
        entries.insert(CalcHistoryEntry(id: id, question: question, answer: answer, kind: kind, date: date,
                                        pinned: pinned), at: 0)
        var unpinned = 0
        entries = entries.filter { entry in
            if entry.pinned { return true }
            unpinned += 1
            return unpinned <= Self.limit
        }
    }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned = pinned
    }

    /// Clears everything, or everything but the pinned entries.
    public mutating func clear(keepingPinned: Bool) {
        entries = keepingPinned ? entries.filter(\.pinned) : []
    }

    /// Entries whose question or answer contains every word of `query` (case and accents ignored).
    public func search(_ query: String) -> [CalcHistoryEntry] {
        let words = FuzzyMatch.normalize(query).split(separator: " ")
        guard !words.isEmpty else { return sorted }
        return sorted.filter { entry in
            let haystack = FuzzyMatch.normalize("\(entry.question) \(entry.answer)")
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

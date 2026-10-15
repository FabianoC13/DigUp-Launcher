import CoreServices
import Foundation

/// Word definitions from the dictionaries in the Dictionary app (DictionaryServices).
enum CalculatorDictionary {
    /// The definition of `term` from the user's active dictionaries, laid out in paragraphs; nil if none has it.
    nonisolated static func definition(of term: String) -> String? {
        let range = CFRange(location: 0, length: (term as NSString).length)
        guard range.length > 0, let found = DCSCopyTextDefinition(nil, term as CFString, range) else { return nil }
        let text = found.takeRetainedValue() as String
        return text.isEmpty ? nil : layout(text)
    }

    /// The dictionary's one-line text with its sections ("ORIGIN", "DERIVATIVES"…) and numbered senses on lines of
    /// their own.
    nonisolated static func layout(_ raw: String) -> String {
        var text = raw
        for heading in ["PHRASAL VERBS", "PHRASES", "DERIVATIVES", "ORIGIN", "USAGE", "NOTE", "SYNONYMS"] {
            text = text.replacingOccurrences(of: " \(heading) ", with: "\n\n\(heading)\n")
        }
        // Senses: "… way. 2 a person …" → a new line before each number that follows a sentence.
        for n in 2...12 {
            text = text.replacingOccurrences(of: ". \(n) ", with: ".\n\(n) ")
            text = text.replacingOccurrences(of: ": \(n) ", with: ":\n\(n) ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first sense, short enough for a row's subtitle.
    nonisolated static func summary(_ definition: String) -> String {
        let firstParagraph = definition.split(separator: "\n").first.map(String.init) ?? definition
        guard firstParagraph.count > 140 else { return firstParagraph }
        return String(firstParagraph.prefix(139)) + "…"
    }

    /// The Dictionary app at `term`.
    static func url(for term: String) -> URL? {
        URL(string: "dict://" + (term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? term))
    }
}

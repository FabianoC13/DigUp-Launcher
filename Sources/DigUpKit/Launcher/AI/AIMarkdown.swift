import Foundation

/// What a line of an answer's Markdown is, for drawing block structure that `AttributedString(markdown:)` leaves out
/// (it handles inline formatting only): headings, list items, quotes, rules and table rows.
public enum AIMarkdownLine: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// "- item", "* item", "+ item"; a task item's "[ ]" / "[x]" becomes ☐ / ☑.
    case bullet(indent: Int, text: String)
    /// "1. item", "2) item".
    case numbered(indent: Int, number: String, text: String)
    case quote(String)
    /// "---", "***", "___".
    case rule
    case tableRow([String])
    /// A table's "|---|:---:|" line.
    case tableSeparator
    case blank
    case text(String)

    public static func classify(_ line: String) -> AIMarkdownLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        let indent = indentLevel(line)
        if let first = trimmed.first, "-*_".contains(first), trimmed.count >= 3,
           trimmed.allSatisfy({ $0 == first || $0 == " " }), trimmed.filter({ $0 == first }).count >= 3 {
            return .rule
        }
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix { $0 == "#" }.count
            let rest = trimmed.dropFirst(level)
            if level <= 6, rest.isEmpty || rest.hasPrefix(" ") {
                var text = rest.trimmingCharacters(in: .whitespaces)
                while text.hasSuffix("#") { text.removeLast() }
                return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
            }
        }
        for marker in ["- ", "* ", "+ ", "• "] where trimmed.hasPrefix(marker) {
            var text = String(trimmed.dropFirst(marker.count))
            if text.hasPrefix("[ ] ") {
                text = "☐ " + text.dropFirst(4)
            } else if text.lowercased().hasPrefix("[x] ") {
                text = "☑ " + text.dropFirst(4)
            }
            return .bullet(indent: indent, text: text)
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = trimmed.dropFirst(digits.count)
            if let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().hasPrefix(" ") {
                return .numbered(indent: indent, number: "\(digits)\(mark)",
                                 text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        if trimmed.hasPrefix(">") {
            return .quote(trimmed.drop { $0 == ">" }.trimmingCharacters(in: .whitespaces))
        }
        if trimmed.hasPrefix("|"), trimmed.dropFirst().contains("|") {
            let cells = tableCells(trimmed)
            let isSeparator = !cells.isEmpty && cells.allSatisfy { cell in
                let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return !core.isEmpty && core.allSatisfy { $0 == "-" }
            }
            return isSeparator ? .tableSeparator : .tableRow(cells)
        }
        return .text(line)
    }

    /// The cells of "| a | b |", trimmed.
    public static func tableCells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Nesting from leading spaces: two per level, a tab counts as four.
    static func indentLevel(_ line: String) -> Int {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 4 } else { break }
        }
        return spaces / 2
    }
}

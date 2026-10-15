import Foundation

/// The text of a note (Markdown): its title, plain text and excerpts, for the launcher's Notes.
public enum NotesText {
    /// The longest title shown; longer first lines are cut at a word.
    public static let maxTitleLength = 80

    /// The note's title: its first line with text, without Markdown's heading, quote, list and task markers or
    /// emphasis ("# **Groceries**" → "Groceries"). "Untitled Note" for an empty note.
    public static func title(of text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let plain = inlinePlain(stripBlockMarkers(String(line))).trimmingCharacters(in: .whitespaces)
            if plain.isEmpty || plain.allSatisfy({ "-*_=`~".contains($0) }) { continue }
            return shortened(plain, to: maxTitleLength)
        }
        return "Untitled Note"
    }

    /// The text after the title line, in one line, for a row's subtitle ("" when there's nothing more).
    public static func excerpt(of text: String, length: Int = 120) -> String {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let first = lines.firstIndex(where: { !inlinePlain(stripBlockMarkers($0)).trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines.removeSubrange(...first)
        }
        let joined = lines.map { inlinePlain(stripBlockMarkers($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy({ "-*_=`~".contains($0) }) }
            .joined(separator: " ")
        return shortened(joined, to: length)
    }

    /// The words around the first place `query` is in `text` ("…the meeting about the budget on…"), or nil when
    /// it isn't there. Case and accents don't count; words cut by the edges are left out.
    public static func snippet(of text: String, matching query: String, radius: Int = 40) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        var start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        // Whole words only: a word the window starts or ends inside goes.
        if start > text.startIndex, !text[text.index(before: start)].isWhitespace,
           let space = text[start..<range.lowerBound].firstIndex(where: \.isWhitespace) {
            start = text.index(after: space)
        }
        if end < text.endIndex, !text[end].isWhitespace,
           let space = text[range.upperBound..<end].lastIndex(where: \.isWhitespace) {
            end = space
        }
        var snippet = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }

    /// The note as plain text, for pasting where Markdown would show its marks: headings, emphasis, inline code and
    /// links lose their marks; list items keep a bullet ("•"), tasks a box ("☐", "☑"), code blocks their lines.
    public static func plainText(fromMarkdown markdown: String) -> String {
        var lines: [String] = []
        var inCode = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            if inCode {
                lines.append(line)
                continue
            }
            if !trimmed.isEmpty, trimmed.count >= 3, Set(trimmed.filter { !$0.isWhitespace }).count == 1,
               let mark = trimmed.first, "-*_".contains(mark) {
                lines.append("")   // a horizontal rule
                continue
            }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            var body = Substring(trimmed)
            var prefix = ""
            while body.hasPrefix(">") { body = body.dropFirst().drop { $0 == " " } }
            if body.hasPrefix("#") {
                let hashes = body.prefix { $0 == "#" }
                if hashes.count <= 6, body.dropFirst(hashes.count).first == " " { body = body.dropFirst(hashes.count + 1) }
            }
            for (marker, replacement) in [("- [ ] ", "☐ "), ("* [ ] ", "☐ "), ("- [x] ", "☑ "), ("- [X] ", "☑ "),
                                          ("* [x] ", "☑ "), ("* [X] ", "☑ "), ("- ", "• "), ("* ", "• "), ("+ ", "• ")]
            where body.hasPrefix(marker) {
                body = body.dropFirst(marker.count)
                prefix = replacement
                break
            }
            lines.append(indent + prefix + inlinePlain(String(body)))
        }
        return lines.joined(separator: "\n")
    }

    /// Without inline Markdown: **bold**, *italic*, _italic_, ~~struck~~, `code`, [text](url) → text, ![alt](url) →
    /// alt, <u>underline</u> → underline. Backslash escapes keep the character.
    public static func inlinePlain(_ text: String) -> String {
        var result = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, "\\`*_{}[]()#+-.!~<>".contains(characters[index + 1]) {
                result.append(characters[index + 1])
                index += 2
                continue
            }
            // [text](url) and ![alt](url): keep the text.
            if character == "[" || (character == "!" && index + 1 < characters.count && characters[index + 1] == "[") {
                let open = character == "[" ? index : index + 1
                if let close = characters[open...].firstIndex(of: "]"), close + 1 < characters.count,
                   characters[close + 1] == "(", let end = characters[(close + 1)...].firstIndex(of: ")") {
                    result += inlinePlain(String(characters[(open + 1)..<close]))
                    index = end + 1
                    continue
                }
            }
            if character == "<" {
                let rest = String(characters[index...])
                if let tag = ["<u>", "</u>", "<b>", "</b>", "<i>", "</i>", "<br>", "<br/>"].first(where: { rest.hasPrefix($0) }) {
                    if tag.hasPrefix("<br") { result.append("\n") }
                    index += tag.count
                    continue
                }
            }
            if "*_~`".contains(character) {
                // Emphasis marks only around words: "a * b" and snake_case keep theirs.
                let previous = index > 0 ? characters[index - 1] : " "
                var run = 1
                while index + run < characters.count, characters[index + run] == character { run += 1 }
                let next = index + run < characters.count ? characters[index + run] : " "
                let opens = !next.isWhitespace && (previous.isWhitespace || previous.isPunctuation || index == 0)
                let closes = !previous.isWhitespace && (next.isWhitespace || next.isPunctuation)
                if character == "`" || opens || closes, !(character == "_" && previous.isLetter && next.isLetter) {
                    index += run
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// A line without its block markers: "#", ">", "- ", "1. ", "- [ ] ".
    static func stripBlockMarkers(_ line: String) -> String {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        while body.hasPrefix(">") { body = body.dropFirst().drop { $0 == " " } }
        body = body.drop { $0 == "#" }.drop { $0 == " " }
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "- ", "* ", "+ "] where body.hasPrefix(marker) {
            body = body.dropFirst(marker.count)
            break
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") { body = body.dropFirst(digits.count + 2) }
        return String(body)
    }

    /// At most `length` characters, cut at a word with "…".
    static func shortened(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        let cut = text.prefix(length)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The note window's formatting keys, as edits of Markdown text: a line's block marker (heading, bullet, task) and
/// inline marks around a selection (bold, italic, code, strikethrough). Each returns the new text of what it changes.
public enum NotesEditing {
    public enum Block: Sendable, Equatable {
        case heading(Int), bullet, numbered, task, quote
    }

    /// A line with `block` toggled: on (replacing another block marker, keeping the indent), or off when the line
    /// already is one. A task's box stays checked or unchecked when it's turned into something else and back.
    public static func toggle(_ block: Block, line: String) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = String(line.dropFirst(indent.count))
        let (current, rest) = marker(of: body)
        if current == block { return indent + rest }
        let prefix: String
        switch block {
        case .heading(let level): prefix = String(repeating: "#", count: max(1, min(6, level))) + " "
        case .bullet: prefix = "- "
        case .numbered: prefix = "1. "
        case .task: prefix = "- [ ] "
        case .quote: prefix = "> "
        }
        return indent + prefix + rest
    }

    /// A task line checked or unchecked ("- [ ] milk" ↔ "- [x] milk"); any other line becomes an unchecked task.
    public static func toggleTask(line: String) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(indent.count)
        for (from, to) in [("- [ ] ", "- [x] "), ("* [ ] ", "* [x] "), ("- [x] ", "- [ ] "), ("- [X] ", "- [ ] "),
                           ("* [x] ", "* [ ] "), ("* [X] ", "* [ ] ")] where body.hasPrefix(from) {
            return indent + to + body.dropFirst(from.count)
        }
        return toggle(.task, line: line)
    }

    /// The block marker a line starts with, and the line after it.
    static func marker(of body: String) -> (Block?, String) {
        for task in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] "] where body.hasPrefix(task) {
            return (.task, String(body.dropFirst(task.count)))
        }
        let hashes = body.prefix { $0 == "#" }
        if (1...6).contains(hashes.count), body.dropFirst(hashes.count).hasPrefix(" ") {
            return (.heading(hashes.count), String(body.dropFirst(hashes.count + 1)))
        }
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            return (.bullet, String(body.dropFirst(bullet.count)))
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") {
            return (.numbered, String(body.dropFirst(digits.count + 2)))
        }
        if body.hasPrefix("> ") { return (.quote, String(body.dropFirst(2))) }
        return (nil, body)
    }

    /// `selection` with `mark` around it ("**bold**"), or without it when it already has it, either inside the
    /// selection or just outside: `before` and `after` are the characters around the selection. Returns the
    /// replacement and how many characters of the outside it takes in on each side.
    public static func wrap(_ selection: String, mark: String, before: String, after: String)
        -> (replacement: String, outside: Int) {
        if selection.count >= 2 * mark.count, selection.hasPrefix(mark), selection.hasSuffix(mark) {
            return (String(selection.dropFirst(mark.count).dropLast(mark.count)), 0)
        }
        if before.hasSuffix(mark), after.hasPrefix(mark) {
            return (selection, mark.count)
        }
        return (mark + selection + mark, 0)
    }

    /// Words in a note, for the window's count.
    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
}

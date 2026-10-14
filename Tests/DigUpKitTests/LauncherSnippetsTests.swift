import Foundation
import Testing
@testable import DigUpKit

@Suite struct LauncherSnippetsPlaceholderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)   // Friday 2027-01-15 08:00 UTC

    func values(clipboard: [String] = ["copied text"], arguments: [String: String] = [:],
                snippets: [String: String] = [:]) -> SnippetPlaceholderValues {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return SnippetPlaceholderValues(
            now: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(identifier: "UTC")!,
            clipboard: { clipboard.indices.contains($0) ? clipboard[$0] : nil },
            selection: { "selected" },
            snippet: { snippets[$0] },
            arguments: arguments,
            uuid: { "UUID-1" })
    }

    func expand(_ template: String, _ values: SnippetPlaceholderValues? = nil) -> String {
        SnippetPlaceholders.expand(template, values: values ?? self.values()).text
    }

    @Test func plainTextStaysAsIs() {
        #expect(expand("Hello, world") == "Hello, world")
        #expect(expand("") == "")
        #expect(!SnippetPlaceholders.hasPlaceholders("function() { return 1 }"))
        #expect(SnippetPlaceholders.hasPlaceholders("Hi {clipboard}"))
    }

    @Test func clipboardAndSelection() {
        #expect(expand("Re: {clipboard}") == "Re: copied text")
        #expect(expand("{clipboard offset=1}", values(clipboard: ["now", "before"])) == "before")
        #expect(expand("[{clipboard offset=5}]") == "[]")
        #expect(expand("{selection}!") == "selected!")
    }

    @Test func datesWithFormatsAndOffsets() {
        #expect(expand("{date format=\"yyyy-MM-dd\"}") == "2027-01-15")
        #expect(expand("{date format=\"yyyy-MM-dd\" offset=\"+3d\"}") == "2027-01-18")
        #expect(expand("{date format=\"yyyy-MM-dd\" offset=\"-1w\"}") == "2027-01-08")
        #expect(expand("{date format=\"yyyy-MM-dd HH:mm\" offset=\"+2y +1M -30m\"}") == "2029-02-15 07:30")
        #expect(expand("{time format=\"HH:mm\" offset=+2h}") == "10:00")
        #expect(expand("{day}") == "Friday")
        #expect(expand("{day locale=\"fr-FR\"}") == "vendredi")
        #expect(expand("{date}") == "Jan 15, 2027")
        #expect(expand("{datetime}").hasPrefix("Jan 15, 2027"))
        #expect(expand("{time}").contains("8:00"))
    }

    @Test func badOffsetsAndLocalesStayLiteral() {
        #expect(expand("{date offset=\"+3x\"}") == "{date offset=\"+3x\"}")
        #expect(expand("{date locale=\"zz-QQ\"}") == "{date locale=\"zz-QQ\"}")
    }

    @Test func uuidAndUnknownPlaceholders() {
        #expect(expand("id: {uuid}") == "id: UUID-1")
        #expect(expand("{unknown} and {clipboard") == "{unknown} and {clipboard")
        #expect(expand("{ not a placeholder }") == "{ not a placeholder }")
        #expect(expand("{{clipboard}}") == "{copied text}")
    }

    @Test func modifiersChain() {
        #expect(expand("{clipboard | uppercase}") == "COPIED TEXT")
        #expect(expand("{clipboard|trim|uppercase}", values(clipboard: ["  hi  "])) == "HI")
        #expect(expand("q={clipboard | percent-encode}", values(clipboard: ["a b&c/é"])) == "q=a%20b%26c%2F%C3%A9")
        #expect(expand("\"{clipboard | json-stringify}\"", values(clipboard: ["say \"hi\"\n"]))
                    == "\"say \\\"hi\\\"\\n\"")
        #expect(expand("{clipboard | raw}") == "copied text")
        #expect(expand("{clipboard | shout}") == "{clipboard | shout}")
    }

    @Test func cursorCountsCharactersAfterIt() {
        let expansion = SnippetPlaceholders.expand("<b>{cursor}</b>", values: values())
        #expect(expansion.text == "<b></b>")
        #expect(expansion.charactersAfterCursor == 4)
        let emoji = SnippetPlaceholders.expand("Hi {cursor}👋🏽 é{cursor}!", values: values())
        #expect(emoji.text == "Hi 👋🏽 é!")
        #expect(emoji.charactersAfterCursor == 4)
        #expect(SnippetPlaceholders.expand("none", values: values()).charactersAfterCursor == nil)
        #expect(SnippetPlaceholders.expand("end{cursor}", values: values()).charactersAfterCursor == 0)
    }

    @Test func argumentsShareValuesByName() {
        let template = "Hi {argument name=\"who\"}, {argument name=\"who\" | uppercase}! {argument default=\"x\"} "
            + "{argument name=\"tone\" options=\"warm, cold\"}"
        let arguments = SnippetPlaceholders.arguments(in: template)
        #expect(arguments.map(\.key) == ["who", "#1", "tone"])
        #expect(arguments[1].name == "Argument")
        #expect(arguments[1].defaultValue == "x")
        #expect(arguments[2].options == ["warm", "cold"])
        #expect(expand(template, values(arguments: ["who": "Ana", "tone": "warm"])) == "Hi Ana, ANA! x warm")
    }

    @Test func embeddedSnippetsGoOneLevelDeep() {
        let snippets = ["sig": "Best, {argument name=\"me\"} {snippet name=\"sig\"}", "plain": "Plain"]
        let template = "Thanks!\n{snippet name=\"sig\"}\n{snippet name=\"plain\" | uppercase}\n{snippet name=\"none\"}"
        let result = expand(template, values(arguments: ["me": "Ana"], snippets: snippets))
        #expect(result == "Thanks!\nBest, Ana {snippet name=\"sig\"}\nPLAIN\n{snippet name=\"none\"}")
        let arguments = SnippetPlaceholders.arguments(in: template, snippet: { snippets[$0] })
        #expect(arguments.map(\.key) == ["me"])
    }

    @Test func offsetsParse() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let shifted = try #require(SnippetPlaceholders.shift(now, by: "+1d +2h", calendar: calendar))
        #expect(shifted.timeIntervalSince(now) == 26 * 3600)
        #expect(SnippetPlaceholders.shift(now, by: "", calendar: calendar) == nil)
        #expect(SnippetPlaceholders.shift(now, by: "+d", calendar: calendar) == nil)
        #expect(SnippetPlaceholders.isKnownLocale("en-US-u-hc-h23"))
        #expect(SnippetPlaceholders.isKnownLocale("de"))
        #expect(!SnippetPlaceholders.isKnownLocale("zz-QQ"))
    }
}

@Suite struct LauncherSnippetsKeywordTests {
    @Test func immediateExpansionOnTheLastCharacter() {
        var matcher = SnippetKeywordMatcher(keywords: [";sig", ";addr", ";addr2"])
        #expect(matcher.typed("hello ") == nil)
        #expect(matcher.typed(";si") == nil)
        let match = matcher.typed("g")
        #expect(match == .init(keyword: ";sig", deleteCount: 4, delimiter: ""))
        #expect(matcher.buffer.isEmpty)
        // The shorter keyword fires first when typed immediately.
        #expect(matcher.typed(";addr")?.keyword == ";addr")
    }

    @Test func longestKeywordWinsWhenBothEnd() {
        var matcher = SnippetKeywordMatcher(keywords: ["dr", "addr"])
        #expect(matcher.typed("addr")?.keyword == "addr")
    }

    @Test func backspaceAndReset() {
        var matcher = SnippetKeywordMatcher(keywords: ["xyz"])
        #expect(matcher.typed("xyq") == nil)
        matcher.deleteBackward()
        #expect(matcher.typed("z")?.keyword == "xyz")
        #expect(matcher.typed("xy") == nil)
        matcher.reset()
        #expect(matcher.typed("z") == nil)
        #expect(matcher.typed("x\ny") == nil)
        #expect(matcher.typed("z") == nil)
    }

    @Test func withinWordsOrNot() {
        var inside = SnippetKeywordMatcher(keywords: ["btw"], expandWithinWords: true)
        #expect(inside.typed("abtw")?.keyword == "btw")
        var words = SnippetKeywordMatcher(keywords: ["btw"], expandWithinWords: false)
        #expect(words.typed("abtw") == nil)
        #expect(words.typed(" btw")?.keyword == "btw")
        #expect(words.typed("btw")?.keyword == "btw")   // right after a reset: a word of its own
        #expect(words.typed("(btw")?.keyword == "btw")
    }

    @Test func afterADelimiter() {
        var matcher = SnippetKeywordMatcher(keywords: ["btw", ";d"], trigger: .afterDelimiter)
        #expect(matcher.typed("btw") == nil)
        #expect(matcher.typed(" ") == .init(keyword: "btw", deleteCount: 4, delimiter: " "))
        #expect(matcher.typed(";d") == nil)
        #expect(matcher.typed(",") == .init(keyword: ";d", deleteCount: 3, delimiter: ","))
        #expect(matcher.typed("btwx ") == nil)
    }

    @Test func noKeywordsNoWork() {
        var matcher = SnippetKeywordMatcher()
        #expect(matcher.typed("anything") == nil)
        #expect(matcher.buffer.isEmpty)
        matcher.setKeywords(["a", ""])
        #expect(matcher.keywords == ["a"])
        #expect(matcher.typed("a")?.keyword == "a")
    }

    @Test func theBufferStaysShort() {
        var matcher = SnippetKeywordMatcher(keywords: ["abc"])
        _ = matcher.typed(String(repeating: "x", count: 100))
        #expect(matcher.buffer.count <= 5)
    }
}

@Suite struct LauncherSnippetsLibraryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func keywordRules() {
        let snippets = [Snippet(id: "1", name: "Signature", text: "Ana", keyword: ";sig")]
        #expect(SnippetLibrary.keywordProblem(";sig", id: "1", in: snippets) == nil)
        #expect(SnippetLibrary.keywordProblem(";sig", id: "2", in: snippets) != nil)
        #expect(SnippetLibrary.keywordProblem("a b", id: nil, in: snippets) != nil)
        #expect(SnippetLibrary.keywordProblem("a`b", id: nil, in: snippets) != nil)
        #expect(SnippetLibrary.keywordProblem("", id: nil, in: snippets) == nil)
    }

    @Test func searchByNameKeywordAndText() throws {
        let snippet = Snippet(name: "Home Address", text: "221B Baker Street, London", keyword: ";addr",
                              tags: ["personal"])
        let byName = try #require(SnippetLibrary.score(snippet, query: "home"))
        let byKeyword = try #require(SnippetLibrary.score(snippet, query: ";addr"))
        let byText = try #require(SnippetLibrary.score(snippet, query: "baker london"))
        #expect(byKeyword > byText)
        #expect(byName > byText)
        #expect(SnippetLibrary.score(snippet, query: "personal") != nil)
        #expect(SnippetLibrary.score(snippet, query: "paris") == nil)
    }

    @Test func duplicatesGetANewNameAndNoKeyword() {
        let original = Snippet(name: "Greeting", text: "Hi", keyword: "hi;")
        let first = SnippetLibrary.duplicate(original, in: [original], now: now)
        #expect(first.name == "Greeting Copy")
        #expect(first.keyword == nil)
        #expect(first.id != original.id)
        let second = SnippetLibrary.duplicate(original, in: [original, first], now: now)
        #expect(second.name == "Greeting Copy 2")
    }

    @Test func importsRaycastExportsSkippingDuplicates() throws {
        let existing = [Snippet(name: "Sig", text: "Ana", keyword: ";sig")]
        let json = """
            [
              {"name": "Sig", "text": "Ana", "keyword": ";sig"},
              {"name": "Other sig", "text": "Bob", "keyword": ";sig"},
              {"text": "No name here\\nsecond line"},
              {"title": "Espanso-ish", "content": "Hello", "trigger": ":hello"},
              {"name": "Empty"}
            ]
            """
        let imported = try SnippetLibrary.importing(Data(json.utf8), into: existing, now: now)
        #expect(imported.added == 3)
        #expect(imported.duplicates == 1)
        #expect(imported.keywordsDropped == 1)
        #expect(imported.snippets.map(\.name) == ["Sig", "Other sig", "No name here", "Espanso-ish"])
        #expect(imported.snippets[1].keyword == nil)
        #expect(imported.snippets[3].keyword == ":hello")
        #expect(throws: SnippetLibrary.ImportError.notSnippets) {
            try SnippetLibrary.importing(Data("{\"a\": 1}".utf8), into: [])
        }
    }

    @Test func exportsRaycastsFormat() throws {
        let data = try SnippetLibrary.exportData([Snippet(name: "A", text: "x", keyword: "a;"),
                                                  Snippet(name: "B", text: "y")])
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(array == [["name": "A", "text": "x", "keyword": "a;"], ["name": "B", "text": "y"]])
        let back = try SnippetLibrary.importing(data, into: [])
        #expect(back.added == 2)
    }

    @Test func storedSnippetsDecodeLeniently() throws {
        let json = #"[{"name": "A", "text": "x", "keyword": ""}]"#
        let decoded = try JSONDecoder().decode([Snippet].self, from: Data(json.utf8))
        #expect(decoded.first?.keyword == nil)
        #expect(decoded.first?.tags == [])
        #expect(decoded.first?.id.isEmpty == false)
    }

    @Test func defaultNames() {
        #expect(SnippetLibrary.defaultName(for: "\n  Dear team,\nthanks") == "Dear team,")
        #expect(SnippetLibrary.defaultName(for: "") == "Untitled Snippet")
        #expect(SnippetLibrary.defaultName(for: String(repeating: "w", count: 60)).count == 40)
    }
}

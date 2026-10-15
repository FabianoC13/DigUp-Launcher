import Foundation
import Testing
@testable import DigUpKit

@Suite struct LauncherQuicklinksTemplateTests {
    let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2027-01-15 10:30:00 UTC, a Friday.
    let now = Date(timeIntervalSince1970: 1_800_009_000)

    func values(_ arguments: [String: String] = [:], clipboard: String? = nil) -> QuicklinkTemplate.Values {
        QuicklinkTemplate.Values(arguments: arguments, clipboard: clipboard, date: now, calendar: utc,
                                 locale: Locale(identifier: "en_US_POSIX"), makeUUID: { "UUID-1" })
    }

    @Test func queryIsPercentEncoded() {
        let template = QuicklinkTemplate("https://www.google.com/search?q={query}")
        #expect(template.takesArgument)
        #expect(template.arguments.map(\.key) == ["query"])
        #expect(template.filled(values(["query": "cats & dogs?"]))
            == "https://www.google.com/search?q=cats%20%26%20dogs%3F")
        #expect(template.filled(values(["query": "café/über"]))
            == "https://www.google.com/search?q=caf%C3%A9%2F%C3%BCber")
    }

    @Test func unnamedArgumentSharesTheQuery() {
        let template = QuicklinkTemplate("https://x.com/{argument}/{query}")
        #expect(template.arguments.count == 1)
        #expect(template.filled(values(["query": "a b"])) == "https://x.com/a%20b/a%20b")
    }

    @Test func namedArgumentsWithDefaultsAndOptions() throws {
        let link = #"https://translate.google.com/?sl={argument name="from" default="auto"}&tl={argument name="to" options="en, fr,de"}&text={query}"#
        let template = QuicklinkTemplate(link)
        #expect(template.arguments.map(\.key) == ["from", "to", "query"])
        let from = try #require(template.arguments.first)
        #expect(from.defaultValue == "auto" && !from.isRequired)
        #expect(template.arguments[1].options == ["en", "fr", "de"])
        #expect(template.arguments[1].isRequired)
        #expect(template.filled(values(["to": "fr", "query": "hello"]))
            == "https://translate.google.com/?sl=auto&tl=fr&text=hello")
    }

    @Test func modifiersAndRaw() {
        #expect(QuicklinkTemplate("https://x.com/{query | trim | uppercase}").filled(values(["query": "  ab c "]))
            == "https://x.com/AB%20C")
        #expect(QuicklinkTemplate("https://x.com/{query | raw}").filled(values(["query": "a/b?c"]))
            == "https://x.com/a/b?c")
        #expect(QuicklinkTemplate("https://x.com/?j={query | json-stringify | raw}").filled(values(["query": "say \"hi\""]))
            == #"https://x.com/?j="say \"hi\"""#)
        // Encoded once, not twice.
        #expect(QuicklinkTemplate("https://x.com/{query | percent-encode}").filled(values(["query": "a b"]))
            == "https://x.com/a%20b")
    }

    @Test func clipboardDateAndUUID() {
        let template = QuicklinkTemplate(#"https://x.com/{clipboard}/{date format="yyyy-MM-dd"}/{date format="yyyy-MM-dd" offset="+1d -1y"}/{uuid}"#)
        #expect(!template.takesArgument)
        #expect(template.usesClipboard)
        #expect(!QuicklinkTemplate("https://x.com/{query}").usesClipboard)
        #expect(template.filled(values(clipboard: "copied text"))
            == "https://x.com/copied%20text/2027-01-15/2026-01-16/UUID-1")
        #expect(QuicklinkTemplate("https://x.com/{day}").filled(values()) == "https://x.com/Friday")
        #expect(QuicklinkTemplate(#"https://x.com/{time format="HH:mm" offset="+90m"}"#).filled(values())
            == "https://x.com/12%3A00")
    }

    @Test func pathsAreNotEncoded() {
        let template = QuicklinkTemplate("~/Notes/{query}.md")
        #expect(!template.encodesByDefault)
        #expect(template.filled(values(["query": "my note"])) == "~/Notes/my note.md")
    }

    @Test func unknownBracesStayText() {
        let template = QuicklinkTemplate("https://x.com/{selection}/{ query }/{unclosed")
        #expect(template.arguments.map(\.key) == ["query"])
        #expect(template.filled(values(["query": "q"])) == "https://x.com/{selection}/q/{unclosed")
    }

    @Test func destinations() {
        #expect(QuicklinkTemplate.destination("https://a.com/x?q=1", home: "/Users/me")?.absoluteString
            == "https://a.com/x?q=1")
        #expect(QuicklinkTemplate.destination("github.com/apple", home: "/Users/me")?.absoluteString
            == "https://github.com/apple")
        #expect(QuicklinkTemplate.destination("localhost:3000/app", home: "/Users/me")?.absoluteString
            == "http://localhost:3000/app")
        #expect(QuicklinkTemplate.destination("~/Downloads", home: "/Users/me")?.path == "/Users/me/Downloads")
        #expect(QuicklinkTemplate.destination("/Applications", home: "/Users/me")?.isFileURL == true)
        #expect(QuicklinkTemplate.destination("slack://open", home: "/Users/me")?.scheme == "slack")
        #expect(QuicklinkTemplate.destination("x-apple.systempreferences:com.apple.Displays-Settings.extension",
                                              home: "/")?.scheme == "x-apple.systempreferences")
        #expect(QuicklinkTemplate.destination("not a link", home: "/") == nil)
        #expect(QuicklinkTemplate.destination("   ", home: "/") == nil)
    }

    @Test func argumentPrompts() {
        let query = QuicklinkTemplate("https://g.com/?q={query}").arguments[0]
        #expect(QuicklinkTemplate.prompt(for: query, quicklinkName: "Google Search") == "Search Google…")
        #expect(QuicklinkTemplate.prompt(for: query, quicklinkName: "YouTube") == "Search YouTube…")
        #expect(QuicklinkTemplate.prompt(for: query, quicklinkName: "Search") == "Search Search…")
        let named = QuicklinkTemplate(#"https://t.com/?tl={argument name="to" default="en"}"#).arguments[0]
        #expect(QuicklinkTemplate.prompt(for: named, quicklinkName: "Translate") == "To (en)…")
    }

    @Test func displayAndHost() {
        #expect(QuicklinkTemplate.display("https://www.google.com/search?q={query}") == "google.com/search?q={query}")
        #expect(QuicklinkTemplate.webHost("https://www.google.com/maps/search/{query}") == "www.google.com")
        #expect(QuicklinkTemplate.webHost("~/Notes") == nil)
        #expect(QuicklinkTemplate.webHost("slack://open") == nil)
    }
}

@Suite struct LauncherQuicklinksMatcherTests {
    @Test func nameThenArgument() throws {
        let match = try #require(QuicklinkMatcher.match("google cats", name: "Google Search", keyword: nil,
                                                        takesArgument: true))
        #expect(match.argument == "cats")
        #expect(match.score > 0.9)
    }

    @Test func argumentKeepsItsCaseAndSpaces() throws {
        let match = try #require(QuicklinkMatcher.match("youtube  Lo-Fi  Beats", name: "YouTube", keyword: nil,
                                                        takesArgument: true))
        #expect(match.argument == "Lo-Fi  Beats")
    }

    @Test func longestNamePrefixWins() throws {
        let match = try #require(QuicklinkMatcher.match("google search cats", name: "Google Search", keyword: nil,
                                                        takesArgument: true))
        #expect(match.argument == "cats")
    }

    @Test func keywordThenArgument() throws {
        let match = try #require(QuicklinkMatcher.match("g swift testing", name: "Google Search", keyword: "g",
                                                        takesArgument: true))
        #expect(match.argument == "swift testing")
        #expect(match.score >= 0.98)
        // A single letter that isn't the keyword doesn't name it.
        #expect(QuicklinkMatcher.match("g cats", name: "Google Search", keyword: nil, takesArgument: true) == nil)
    }

    @Test func partialNameWaitsForTheArgument() throws {
        let match = try #require(QuicklinkMatcher.match("goo", name: "Google Search", keyword: nil, takesArgument: true))
        #expect(match.argument == nil)
        let whole = try #require(QuicklinkMatcher.match("google search", name: "Google Search", keyword: nil,
                                                        takesArgument: true))
        #expect(whole.argument == nil && whole.score == 1)
    }

    @Test func linksWithoutArgumentsMatchOnlyWhole() {
        #expect(QuicklinkMatcher.match("downloads", name: "Downloads", keyword: nil, takesArgument: false)?.argument
            == nil)
        #expect(QuicklinkMatcher.match("downloads cats", name: "Downloads", keyword: nil, takesArgument: false) == nil)
        #expect(QuicklinkMatcher.match("xyz", name: "Google Search", keyword: nil, takesArgument: true) == nil)
    }

    @Test func partOfAWordRanksLower() throws {
        let partial = try #require(QuicklinkMatcher.match("goo cats", name: "Google Search", keyword: nil,
                                                          takesArgument: true))
        #expect(partial.argument == "cats")
        #expect(partial.score < 0.75)
        let whole = try #require(QuicklinkMatcher.match("google cats", name: "Google Search", keyword: nil,
                                                        takesArgument: true))
        #expect(whole.score > partial.score)
    }

    @Test func laterWordsOfTheName() throws {
        let maps = try #require(QuicklinkMatcher.match("maps coffee near me", name: "Google Maps", keyword: nil,
                                                       takesArgument: true))
        #expect(maps.argument == "coffee near me")
        #expect(maps.score >= 0.8 && maps.score < 0.9)
        let translate = try #require(QuicklinkMatcher.match("trans hello", name: "Google Translate", keyword: nil,
                                                            takesArgument: true))
        #expect(translate.argument == "hello")
        // Two letters of a later word is too little.
        #expect(QuicklinkMatcher.match("tr hello", name: "Google Translate", keyword: nil, takesArgument: true) == nil)
    }

    @Test func aliasThenArgument() {
        #expect(QuicklinkMatcher.argument(after: "ss", in: "SS  Lo-Fi beats") == "Lo-Fi beats")
        #expect(QuicklinkMatcher.argument(after: "my docs", in: "my  docs swift") == "swift")
        #expect(QuicklinkMatcher.argument(after: "ss", in: "ssx cats") == nil)
        #expect(QuicklinkMatcher.argument(after: "ss", in: "ss") == nil)
        #expect(QuicklinkMatcher.argument(after: "", in: "ss cats") == nil)
    }

    @Test func splits() {
        let parts = QuicklinkMatcher.splits("a b  c").map { "\($0.head)|\($0.tail)" }
        #expect(parts == ["a|b  c", "a b|c"])
        #expect(QuicklinkMatcher.splits("single").isEmpty)
    }

    @Test func libraryLinksAllOpen() {
        #expect(Set(QuicklinkRecord.library.map(\.id)).count == QuicklinkRecord.library.count)
        for record in QuicklinkRecord.library {
            let filled = QuicklinkTemplate(record.link).filled(.init(arguments: ["query": "x", "to": "fr"]))
            #expect(QuicklinkTemplate.destination(filled, home: "/Users/me") != nil, "\(record.name)")
        }
    }

    @Test func keywordsAndNames() {
        let links = [QuicklinkRecord(id: "1", name: "Google Search", link: "https://g.com/{query}", keyword: "g")]
        #expect(QuicklinkRecord.keywordProblem("G", for: "2", among: links) == "“Google Search” has that keyword")
        #expect(QuicklinkRecord.keywordProblem("g", for: "1", among: links) == nil)
        #expect(QuicklinkRecord.keywordProblem("two words", for: "2", among: links) == "A keyword is one word")
        #expect(QuicklinkRecord.keywordProblem("  ", for: "2", among: links) == nil)
        #expect(QuicklinkRecord.suggestedName(for: "https://www.github.com/apple") == "github.com")
        #expect(QuicklinkRecord.suggestedName(for: "~/Documents/Taxes") == "Taxes")
        #expect(QuicklinkRecord.suggestedName(for: "not a link") == "")
    }

    @Test func defaultsDecodeAndRoundTrip() throws {
        var counter = 0
        let defaults = QuicklinkRecord.defaults { counter += 1; return "id\(counter)" }
        #expect(defaults.count == 6)
        #expect(defaults.allSatisfy { QuicklinkTemplate($0.link).takesArgument })
        let data = try JSONEncoder().encode(defaults)
        #expect(try JSONDecoder().decode([QuicklinkRecord].self, from: data) == defaults)
        // Raycast's export: no id, empty openWith.
        let raycast = Data(#"[{"name":"Docs","link":"https://docs.swift.org","openWith":""}]"#.utf8)
        let read = try JSONDecoder().decode([QuicklinkRecord].self, from: raycast)
        #expect(read.first?.name == "Docs" && read.first?.openWith == nil && read.first?.id.isEmpty == false)
    }
}

@Suite struct LauncherQuicklinksDeeplinkTests {
    @Test func runRoundTripsAnItemID() throws {
        let id = "app:/Applications/Safari.app"
        let link = QuicklinksDeeplink.run(itemID: id).url
        #expect(link.absoluteString == "digup://run/app%3A%2FApplications%2FSafari.app")
        #expect(QuicklinksDeeplink(link) == .run(itemID: id))
        // Written by hand, unencoded.
        let typed = try #require(URL(string: "digup://run/cmd:lock-screen"))
        #expect(QuicklinksDeeplink(typed) == .run(itemID: "cmd:lock-screen"))
    }

    @Test func searchAIAndQuicklink() throws {
        #expect(QuicklinksDeeplink(try #require(URL(string: "digup://search?q=tax%20return%202024")))
            == .search(query: "tax return 2024"))
        #expect(QuicklinksDeeplink(try #require(URL(string: "DIGUP://ai?q=what%27s%20new"))) == .ai(prompt: "what's new"))
        #expect(QuicklinksDeeplink(try #require(URL(string: "digup://quicklink/Google%20Search?q=cats")))
            == .quicklink(name: "Google Search", argument: "cats"))
        #expect(QuicklinksDeeplink(try #require(URL(string: "digup://quicklink/gh")))
            == .quicklink(name: "gh", argument: nil))
        #expect(QuicklinksDeeplink.search(query: "a&b").url.absoluteString == "digup://search?q=a%26b")
        #expect(QuicklinksDeeplink(QuicklinksDeeplink.quicklink(name: "Google Search", argument: "a b").url)
            == .quicklink(name: "Google Search", argument: "a b"))
    }

    @Test func otherLinks() throws {
        #expect(QuicklinksDeeplink(try #require(URL(string: "digup://"))) == .show)
        #expect(QuicklinksDeeplink(try #require(URL(string: "digup://whatever"))) == .show)
        #expect(QuicklinksDeeplink(try #require(URL(string: "digup://run/"))) == nil)
        #expect(QuicklinksDeeplink(try #require(URL(string: "https://run/x"))) == nil)
    }
}

@Suite struct LauncherQuicklinksHyperKeyTests {
    typealias Mapping = QuicklinksHyperKeyMapping

    @Test func parsesHidutilOutput() {
        let output = """
        RegistryID  Key                   Value
        100000a8b   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771300;
                HIDKeyboardModifierMappingSrc = 30064771296;
            }
        )
        100000802   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771300;
                HIDKeyboardModifierMappingSrc = 30064771296;
            },
                {
                HIDKeyboardModifierMappingDst = 0x700000029;
                HIDKeyboardModifierMappingSrc = 0x700000039;
            }
        )
        1000007d7   UserKeyMapping   (null)
        """
        #expect(Mapping.parse(output) == [
            .init(source: 30_064_771_296, destination: 30_064_771_300),
            .init(source: Mapping.capsLock, destination: 0x7_0000_0029),
        ])
        #expect(Mapping.parse("100000a8b   UserKeyMapping   (null)\n").isEmpty)
    }

    @Test func enablingReplacesCapsLockAndRemembersIt() {
        let other = Mapping.Pair(source: 0x7_0000_00E0, destination: 0x7_0000_00E3)   // left ⌃ → left ⌘
        let escape = Mapping.Pair(source: Mapping.capsLock, destination: 0x7_0000_0029)
        let (mappings, previous) = Mapping.enabling([other, escape])
        #expect(mappings == [other, Mapping.hyper])
        #expect(previous == 0x7_0000_0029)
        // Turned on twice: nothing to remember the second time.
        #expect(Mapping.enabling(mappings).previousCapsLock == nil)
        #expect(Mapping.enabling(mappings).mappings == mappings)
    }

    @Test func disablingRestores() {
        let other = Mapping.Pair(source: 0x7_0000_00E0, destination: 0x7_0000_00E3)
        #expect(Mapping.disabling([other, Mapping.hyper], restoring: nil) == [other])
        #expect(Mapping.disabling([Mapping.hyper], restoring: 0x7_0000_0029)
            == [.init(source: Mapping.capsLock, destination: 0x7_0000_0029)])
    }

    @Test func tapAddsModifiersWhileHeld() {
        var state = QuicklinksHyperKeyState()
        let f18 = QuicklinksHyperKeyState.f18KeyCode
        #expect(state.handle(keyCode: 0, isDown: true, at: 0) == .pass)
        #expect(state.handle(keyCode: f18, isDown: true, at: 1) == .swallow)
        #expect(state.isHeld)
        #expect(state.handle(keyCode: f18, isDown: true, at: 1.3) == .swallow)   // key repeat
        #expect(state.handle(keyCode: 1, isDown: true, at: 1.5) == .addModifiers)
        #expect(state.handle(keyCode: 1, isDown: false, at: 1.6) == .addModifiers)
        #expect(state.handle(keyCode: f18, isDown: false, at: 1.7) == .swallow)   // used: not a quick press
        #expect(!state.isHeld)
        #expect(state.handle(keyCode: 1, isDown: true, at: 2) == .pass)
    }

    @Test func quickPress() {
        var state = QuicklinksHyperKeyState()
        let f18 = QuicklinksHyperKeyState.f18KeyCode
        #expect(state.handle(keyCode: f18, isDown: true, at: 10) == .swallow)
        #expect(state.handle(keyCode: f18, isDown: false, at: 10.2) == .quickPress)
        // Held too long.
        #expect(state.handle(keyCode: f18, isDown: true, at: 20) == .swallow)
        #expect(state.handle(keyCode: f18, isDown: false, at: 21) == .swallow)
        // A release without a press (after a reset) isn't one either.
        #expect(state.handle(keyCode: f18, isDown: true, at: 30) == .swallow)
        state.reset()
        #expect(state.handle(keyCode: f18, isDown: false, at: 30.1) == .swallow)
    }

    @Test func json() {
        #expect(Mapping.json([Mapping.hyper])
            == #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771181}]}"#)
        #expect(Mapping.json([]) == #"{"UserKeyMapping":[]}"#)
    }
}

@Suite struct LauncherQuicklinksPersonalizationTests {
    @Test func resetRankingKeepsFavoriteAliasAndHotkey() {
        var usage = LauncherUsage()
        usage.recordUse("app:a", query: "saf")
        usage.recordUse("app:b", query: "saf")
        usage.toggleFavorite("app:a")
        usage.aliases["app:a"] = "s"
        usage.hotkeys["app:a"] = "cmd+opt+s"
        #expect(QuicklinksPersonalization.hasRanking("app:a", in: usage))
        QuicklinksPersonalization.resetRanking("app:a", in: &usage)
        #expect(!QuicklinksPersonalization.hasRanking("app:a", in: usage))
        #expect(usage.records["app:b"] != nil && usage.picks["saf"]?["app:b"] == 1)
        #expect(usage.favorites == ["app:a"] && usage.aliases["app:a"] == "s" && usage.hotkeys["app:a"] != nil)
    }

    @Test func moveFavorites() {
        var usage = LauncherUsage()
        usage.favorites = ["a", "b", "c"]
        #expect(QuicklinksPersonalization.moveFavorite("c", by: -1, in: &usage))
        #expect(usage.favorites == ["a", "c", "b"])
        #expect(!QuicklinksPersonalization.moveFavorite("a", by: -1, in: &usage))
        #expect(QuicklinksPersonalization.moveFavorite("a", by: 5, in: &usage))
        #expect(usage.favorites == ["c", "b", "a"])
    }

    @Test func aliasesAndHotkeysMoveBetweenItems() {
        var usage = LauncherUsage()
        QuicklinksPersonalization.setAlias("  Web  ", for: "app:safari", in: &usage)
        #expect(usage.aliases["app:safari"] == "web")
        QuicklinksPersonalization.setAlias("WEB", for: "app:chrome", in: &usage)
        #expect(usage.aliases == ["app:chrome": "web"])
        QuicklinksPersonalization.setAlias("  ", for: "app:chrome", in: &usage)
        #expect(usage.aliases.isEmpty)
        QuicklinksPersonalization.setHotkey("cmd+opt+s", for: "a", in: &usage)
        #expect(QuicklinksPersonalization.hotkeyOwner("cmd+opt+s", in: usage, except: "b") == "a")
        QuicklinksPersonalization.setHotkey("cmd+opt+s", for: "b", in: &usage)
        #expect(usage.hotkeys == ["b": "cmd+opt+s"])
        QuicklinksPersonalization.setHotkey(nil, for: "b", in: &usage)
        #expect(usage.hotkeys.isEmpty)
    }

    @Test func fallbackSearchURLs() {
        #expect(QuicklinksFallbacks.searchURL("google", query: "a&b c")?.absoluteString
            == "https://www.google.com/search?q=a%26b%20c")
        #expect(QuicklinksFallbacks.searchURL("duckduckgo", query: "x")?.absoluteString == "https://duckduckgo.com/?q=x")
        #expect(QuicklinksFallbacks.searchURL("maps", query: "café")?.absoluteString == "maps://?q=caf%C3%A9")
        #expect(QuicklinksFallbacks.searchURL("ai", query: "x") == nil)
        #expect(QuicklinksFallbacks.builtIns.allSatisfy { QuicklinksFallbacks.title(of: $0) != nil })
    }

    @Test func settingsReadOlderFiles() throws {
        let empty = try JSONDecoder().decode(QuicklinksSettings.self, from: Data("{}".utf8))
        #expect(empty == QuicklinksSettings())
        #expect(!empty.hyperKeyEnabled && empty.hyperIncludesShift && empty.hyperQuickPress == .nothing)
        let odd = try JSONDecoder().decode(QuicklinksSettings.self,
                                           from: Data(#"{"hyperQuickPress":"capslock","hyperKeyEnabled":true}"#.utf8))
        #expect(odd.hyperQuickPress == .nothing && odd.hyperKeyEnabled)
        var settings = QuicklinksSettings()
        settings.previousCapsLock = QuicklinksHyperKeyMapping.capsLock
        settings.trustedDeeplinks = ["app:x"]
        settings.fallbacks = [QuicklinksFallbackEntry(id: "ai", enabled: false)]
        #expect(try JSONDecoder().decode(QuicklinksSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func fallbacksNormalize() {
        let saved = [QuicklinksFallbackEntry(id: "files", enabled: false), QuicklinksFallbackEntry(id: "ql:gone", enabled: true),
                     QuicklinksFallbackEntry(id: "google", enabled: true), QuicklinksFallbackEntry(id: "files", enabled: true)]
        let list = QuicklinksFallbacks.normalized(saved, quicklinks: ["x"])
        #expect(list.map(\.id) == ["files", "google", "ai", "duckduckgo", "maps", "ql:x"])
        #expect(list.map(\.enabled) == [false, true, true, true, true, false])
        var entries = list
        QuicklinksFallbacks.move(&entries, at: 0, by: 1)
        #expect(entries.prefix(2).map(\.id) == ["google", "files"])
    }
}

@Suite struct LauncherQuicklinksBackupTests {
    @Test func roundTripsAndReadsRaycastExports() throws {
        let backup = QuicklinksBackup(exported: Date(timeIntervalSince1970: 1_800_000_000), favorites: ["app:a"],
                                      aliases: ["app:a": "a"], hotkeys: ["app:a": "cmd+opt+a"],
                                      quicklinks: [QuicklinkRecord(id: "1", name: "Docs", link: "https://d.com")],
                                      snippets: .array([.object(["id": .string("s1"), "text": .string("hi")])]))
        let data = try QuicklinksBackup.encoder().encode(backup)
        #expect(try QuicklinksBackup.read(data) == backup)
        let raycast = Data(#"[{"name":"Docs","link":"https://d.com"}]"#.utf8)
        #expect(try QuicklinksBackup.read(raycast).quicklinks.map(\.name) == ["Docs"])
        #expect(throws: (any Error).self) { try QuicklinksBackup.read(Data(#"{"format":"other"}"#.utf8)) }
    }

    @Test func mergeKeepsWhatsThere() {
        var links = [QuicklinkRecord(id: "1", name: "Docs", link: "https://d.com", keyword: "d")]
        var usage = LauncherUsage()
        usage.favorites = ["app:a"]
        usage.aliases["app:b"] = "b"
        usage.hotkeys["app:c"] = "cmd+opt+c"
        let backup = QuicklinksBackup(
            favorites: ["app:a", "app:z"],
            aliases: ["app:b": "other", "app:x": "b", "app:y": "y"],
            hotkeys: ["app:d": "cmd+opt+c", "app:e": "cmd+opt+e"],
            quicklinks: [QuicklinkRecord(id: "1", name: "Changed", link: "https://x.com"),
                         QuicklinkRecord(id: "2", name: "docs", link: "https://d.com"),
                         QuicklinkRecord(id: "3", name: "New", link: "https://n.com", keyword: "D")])
        var summary = QuicklinksBackup.Summary()
        backup.mergeQuicklinks(into: &links, summary: &summary)
        backup.mergeUsage(into: &usage, summary: &summary)
        #expect(links.map(\.id) == ["1", "3"])
        #expect(links[0].name == "Docs" && links[1].keyword == nil)
        #expect(usage.favorites == ["app:a", "app:z"])
        #expect(usage.aliases == ["app:b": "b", "app:y": "y"])
        #expect(usage.hotkeys == ["app:c": "cmd+opt+c", "app:e": "cmd+opt+e"])
        #expect(summary.quicklinksAdded == 1 && summary.quicklinksSkipped == 2)
        #expect(summary.favoritesAdded == 1 && summary.aliasesAdded == 1 && summary.aliasesSkipped == 2)
        #expect(summary.hotkeysAdded == 1 && summary.hotkeysSkipped == 1)
    }

    @Test func snippetsMergeWithoutKnowingTheirShape() {
        let existing = QuicklinksJSON.array([.object(["id": .string("a"), "text": .string("one")])])
        let incoming = QuicklinksJSON.array([.object(["id": .string("a"), "text": .string("changed")]),
                                             .object(["id": .string("b"), "text": .string("two")])])
        let (merged, added) = QuicklinksJSON.merge(existing, with: incoming)
        #expect(added == 1)
        #expect(merged == .array([.object(["id": .string("a"), "text": .string("one")]),
                                  .object(["id": .string("b"), "text": .string("two")])]))
        let wrapped = QuicklinksJSON.merge(.object(["snippets": existing, "version": .int(1)]),
                                           with: .object(["snippets": incoming, "version": .int(2)]))
        #expect(wrapped.added == 1)
        #expect(QuicklinksJSON.merge(nil, with: incoming).added == 2)
    }
}

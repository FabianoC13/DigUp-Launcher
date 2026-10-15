import Foundation
import Testing
@testable import DigUpKit

@Suite struct LauncherClipboardKindTests {
    @Test func linksAreWholeWebAddresses() throws {
        #expect(ClipboardClassifier.kind(of: "https://apple.com/mac") == .link)
        #expect(ClipboardClassifier.kind(of: "  www.raycast.com  ") == .link)
        #expect(ClipboardClassifier.kind(of: "http://localhost:8080/x") == .link)
        let url = try #require(ClipboardClassifier.link(in: "www.raycast.com"))
        #expect(url.host == "www.raycast.com")
        #expect(ClipboardClassifier.kind(of: "see https://apple.com") == .text)
        #expect(ClipboardClassifier.kind(of: "file:///etc/hosts") == .text)
        #expect(ClipboardClassifier.kind(of: "https://nodot") == .text)
    }

    @Test func emails() {
        #expect(ClipboardClassifier.kind(of: "ana@example.com") == .email)
        #expect(ClipboardClassifier.email(in: "mailto:ana@example.com") == "ana@example.com")
        #expect(ClipboardClassifier.kind(of: "ana@example") == .text)
        #expect(ClipboardClassifier.kind(of: "a b@example.com") == .text)
    }

    @Test func colorsInCSSNotation() throws {
        #expect(ClipboardClassifier.kind(of: "#FF8800") == .color)
        #expect(ClipboardClassifier.kind(of: "#f80") == .color)
        #expect(ClipboardClassifier.kind(of: "rgb(255, 136, 0)") == .color)
        #expect(ClipboardClassifier.kind(of: "rgba(255 136 0 / 50%)") == .color)
        #expect(ClipboardClassifier.kind(of: "hsl(32, 100%, 50%)") == .color)
        #expect(ClipboardClassifier.kind(of: "#GG0000") == .text)
        #expect(ClipboardClassifier.kind(of: "rgb(300, 0, 0)") == .text)
        let color = try #require(ClipboardColor(parsing: "#FF880080"))
        #expect(color.hex == "#FF880080")
        #expect(color.rgb == "rgba(255, 136, 0, 0.5)")
        let orange = try #require(ClipboardColor(parsing: "rgb(255, 136, 0)"))
        #expect(orange.hex == "#FF8800")
        #expect(orange.hsl == "hsl(32, 100%, 50%)")
        let fromHSL = try #require(ClipboardColor(parsing: "hsl(32, 100%, 50%)"))
        #expect(fromHSL.hex == "#FF8800")
    }

    @Test func codeIsRecognized() {
        #expect(ClipboardClassifier.looksLikeCode("{\"name\": \"DigUp\", \"version\": 7}"))
        #expect(ClipboardClassifier.looksLikeCode("""
            func greet(_ name: String) -> String {
                return "Hello, \\(name)"
            }
            """))
        #expect(ClipboardClassifier.looksLikeCode("git commit -m \"fix\" && git push"))
        #expect(ClipboardClassifier.looksLikeCode("SELECT id, name FROM users WHERE id = 3;"))
        #expect(!ClipboardClassifier.looksLikeCode("Meet me at the café at noon, then we'll walk to the park."))
        #expect(!ClipboardClassifier.looksLikeCode("Hello"))
    }

    @Test func titlesAreTheFirstLineClipped() {
        #expect(ClipboardClassifier.title(of: "\n\n  First line  \nSecond") == "First line")
        let long = String(repeating: "a", count: 200)
        let title = ClipboardClassifier.title(of: long)
        #expect(title.count == ClipboardClassifier.titleLength)
        #expect(title.hasSuffix("…"))
        #expect(ClipboardClassifier.wordCount("It's a fine-day, isn't it?") == 6)
        #expect(ClipboardClassifier.lineCount("a\nb\nc") == 3)
    }

    @Test func entryTitles() {
        let image = ClipboardEntry(kind: .image, imageWidth: 1280, imageHeight: 720, fingerprint: "i")
        #expect(image.title == "Image (1280×720)")
        let files = ClipboardEntry(kind: .files, files: ["/Users/a/Report.pdf", "/Users/a/Notes.txt"], fingerprint: "f")
        #expect(files.title == "Report.pdf, Notes.txt")
        var text = ClipboardEntry(kind: .text, text: "Hello\nworld", fingerprint: "t")
        #expect(text.title == "Hello")
        text.customTitle = "Greeting"
        #expect(text.title == "Greeting")
    }

    @Test func longTextsKeepTheirStartWithinTheLimit() {
        let text = String(repeating: "é", count: 10)   // 2 bytes each
        let prefix = ClipboardEntry.prefix(of: text, bytes: 7)
        #expect(prefix == "ééé")
        #expect(ClipboardEntry.prefix(of: "short", bytes: 100) == "short")
    }
}

@Suite struct LauncherClipboardHistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)   // a Friday, 2027-01-15 08:00 UTC

    func entry(_ text: String, ago seconds: TimeInterval, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(kind: .text, text: text, copied: now.addingTimeInterval(-seconds), pinned: pinned,
                       fingerprint: ClipboardHistoryRules.fingerprint(kind: .text, text: text))
    }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2   // Monday
        return calendar
    }

    @Test func passwordsAndIgnoredAppsAreSkipped() {
        let ignored: Set<String> = ["com.apple.keychainaccess"]
        #expect(ClipboardHistoryRules.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
                                                 sourceBundleID: "com.apple.Safari", ignoredBundleIDs: ignored))
        #expect(ClipboardHistoryRules.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"],
                                                 sourceBundleID: nil, ignoredBundleIDs: ignored))
        #expect(ClipboardHistoryRules.shouldSkip(types: ["com.agilebits.onepassword"],
                                                 sourceBundleID: nil, ignoredBundleIDs: []))
        #expect(ClipboardHistoryRules.shouldSkip(types: ["public.utf8-plain-text"],
                                                 sourceBundleID: "com.apple.keychainaccess", ignoredBundleIDs: ignored))
        #expect(!ClipboardHistoryRules.shouldSkip(types: ["public.utf8-plain-text"],
                                                  sourceBundleID: "com.apple.Safari", ignoredBundleIDs: ignored))
    }

    @Test func fingerprintsTellContentApart() {
        let a = ClipboardHistoryRules.fingerprint(kind: .text, text: "hello")
        #expect(a == ClipboardHistoryRules.fingerprint(kind: .text, text: "hello"))
        #expect(a != ClipboardHistoryRules.fingerprint(kind: .text, text: "hello "))
        #expect(a != ClipboardHistoryRules.fingerprint(kind: .link, text: "hello"))
        let png = ClipboardHistoryRules.fingerprint(kind: .image, data: Data([1, 2, 3]))
        #expect(png != ClipboardHistoryRules.fingerprint(kind: .image, data: Data([1, 2, 4])))
        #expect(a.count == 64)
    }

    @Test func copyingAgainMovesToTheTopKeepingThePin() {
        var history = [entry("new", ago: 10), entry("old", ago: 100, pinned: true), entry("older", ago: 1000)]
        let oldID = history[1].id
        var again = entry("old", ago: 0)
        again.sourceName = "Notes"
        let recorded = ClipboardHistoryRules.record(again, into: history)
        #expect(!recorded.isNew)
        #expect(recorded.id == oldID)
        history = recorded.entries
        #expect(history.map(\.text) == ["old", "new", "older"])
        #expect(history[0].pinned)
        #expect(history[0].timesCopied == 2)
        #expect(history[0].sourceName == "Notes")
        #expect(history[0].copied == now)

        let fresh = ClipboardHistoryRules.record(entry("fresh", ago: 0), into: history)
        #expect(fresh.isNew)
        #expect(fresh.entries.count == 4)
        #expect(fresh.entries.first?.text == "fresh")
    }

    @Test func usingAnEntryMovesItUp() {
        let history = [entry("a", ago: 10), entry("b", ago: 20), entry("c", ago: 30)]
        let touched = ClipboardHistoryRules.touch(history[2].id, in: history, at: now)
        #expect(touched.map(\.text) == ["c", "a", "b"])
    }

    @Test func retentionExpiresUnpinnedEntries() {
        let day = 86_400.0
        let history = [entry("today", ago: 3600), entry("last week", ago: 8 * day),
                       entry("pinned", ago: 400 * day, pinned: true), entry("ancient", ago: 400 * day)]
        let week = ClipboardHistoryRules.pruned(history, retention: .week, now: now)
        #expect(week.kept.map(\.text) == ["today", "pinned"])
        #expect(Set(week.removed.map(\.text)) == ["last week", "ancient"])
        let forever = ClipboardHistoryRules.pruned(history, retention: .forever, now: now)
        #expect(forever.kept.count == 4)
        #expect(forever.removed.isEmpty)
        #expect(ClipboardRetention.standard == .month)
        #expect(ClipboardRetention.month.duration == 30 * day)
    }

    @Test func theLimitDropsTheOldestUnpinned() {
        let history = (0..<6).map { entry("e\($0)", ago: Double($0) * 10, pinned: $0 == 5) }
        let pruned = ClipboardHistoryRules.pruned(history, retention: .forever, now: now, limit: 4)
        #expect(pruned.kept.map(\.text) == ["e0", "e1", "e2", "e5"])
        #expect(pruned.removed.map(\.text) == ["e4", "e3"])
    }

    @Test func clearingKeepsPinned() {
        let history = [entry("a", ago: 60), entry("b", ago: 7200, pinned: true), entry("c", ago: 7200)]
        let all = ClipboardHistoryRules.clearing(history)
        #expect(all.kept.map(\.text) == ["b"])
        let lastHour = ClipboardHistoryRules.clearing(history, since: now.addingTimeInterval(-3600))
        #expect(lastHour.kept.map(\.text) == ["b", "c"])
        #expect(lastHour.removed.map(\.text) == ["a"])
    }

    @Test func sectionsByDay() {
        let calendar = utc
        let day = 86_400.0
        #expect(ClipboardHistoryRules.section(of: entry("x", ago: 60), now: now, calendar: calendar) == .today)
        #expect(ClipboardHistoryRules.section(of: entry("x", ago: day), now: now, calendar: calendar) == .yesterday)
        // Friday: Tuesday is this week, last Friday isn't.
        #expect(ClipboardHistoryRules.section(of: entry("x", ago: 3 * day), now: now, calendar: calendar) == .thisWeek)
        #expect(ClipboardHistoryRules.section(of: entry("x", ago: 7 * day), now: now, calendar: calendar) == .earlier)
        #expect(ClipboardHistoryRules.section(of: entry("x", ago: 7 * day, pinned: true), now: now,
                                              calendar: calendar) == .pinned)
        let ordered = ClipboardHistoryRules.ordered([entry("b", ago: day), entry("a", ago: 60),
                                                     entry("p", ago: 9 * day, pinned: true)],
                                                    now: now, calendar: calendar)
        #expect(ordered.map(\.section) == [.pinned, .today, .yesterday])
    }

    @Test func searchByKindAndWords() {
        let search = ClipboardSearch(parsing: "Images cat")
        #expect(search.kind == .image)
        #expect(search.text == "cat")
        #expect(ClipboardSearch(parsing: "links").kind == .link)
        #expect(ClipboardSearch(parsing: "links").text.isEmpty)
        #expect(ClipboardSearch(parsing: "hello world").kind == nil)

        var image = ClipboardEntry(kind: .image, imageWidth: 10, imageHeight: 10, fingerprint: "i")
        image.recognizedText = "A Cat on a mat"
        let text = entry("The quick brown fox", ago: 0)
        #expect(ClipboardHistoryRules.matches(image, searchText: ClipboardHistoryRules.searchText(of: image),
                                              search: search))
        #expect(!ClipboardHistoryRules.matches(text, searchText: ClipboardHistoryRules.searchText(of: text),
                                               search: search))
        let words = ClipboardSearch(parsing: "fox QUICK")
        #expect(ClipboardHistoryRules.matches(text, searchText: ClipboardHistoryRules.searchText(of: text),
                                              search: words))
        #expect(!ClipboardHistoryRules.matches(text, searchText: ClipboardHistoryRules.searchText(of: text),
                                               search: ClipboardSearch(parsing: "zebra")))
        let files = ClipboardEntry(kind: .files, files: ["/tmp/Quarterly Report.pdf"], fingerprint: "f")
        #expect(ClipboardHistoryRules.matches(files, searchText: ClipboardHistoryRules.searchText(of: files),
                                              search: ClipboardSearch(parsing: "file report")))
    }

    @Test func relativeTimes() {
        let calendar = utc
        #expect(ClipboardHistoryRules.relativeTime(now.addingTimeInterval(-20), now: now, calendar: calendar)
                    == "Just now")
        #expect(ClipboardHistoryRules.relativeTime(now.addingTimeInterval(-300), now: now, calendar: calendar)
                    == "5 min ago")
        #expect(ClipboardHistoryRules.relativeTime(now.addingTimeInterval(-7200), now: now, calendar: calendar)
                    == "2 h ago")
        #expect(ClipboardHistoryRules.relativeTime(now.addingTimeInterval(-86_400), now: now, calendar: calendar)
                    == "Yesterday")
        #expect(ClipboardHistoryRules.relativeTime(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar)
                    == "3 days ago")
        #expect(ClipboardHistoryRules.relativeTime(now.addingTimeInterval(-30 * 86_400), now: now,
                                                   calendar: calendar) == nil)
    }

    @Test func pasteSequenceWalksBackAndStartsOver() {
        var sequence = ClipboardPasteSequence()
        #expect(sequence.next(count: 3, changeCount: 10, now: now) == 0)
        sequence.wrote(changeCount: 11)
        #expect(sequence.next(count: 3, changeCount: 11, now: now.addingTimeInterval(1)) == 1)
        sequence.wrote(changeCount: 12)
        #expect(sequence.next(count: 3, changeCount: 12, now: now.addingTimeInterval(2)) == 2)
        sequence.wrote(changeCount: 13)
        #expect(sequence.next(count: 3, changeCount: 13, now: now.addingTimeInterval(3)) == nil)
        // Someone copied: back to the newest.
        #expect(sequence.next(count: 3, changeCount: 20, now: now.addingTimeInterval(4)) == 0)
        sequence.wrote(changeCount: 21)
        // Too long a pause: back to the newest.
        #expect(sequence.next(count: 3, changeCount: 21, now: now.addingTimeInterval(100)) == 0)
        sequence.reset()
        #expect(sequence.index == nil)
    }

    @Test func entriesRoundTripAndOldIndexesDecode() throws {
        let original = ClipboardEntry(kind: .link, text: "https://apple.com", richTypes: ["public.html"],
                                      sourceName: "Safari", sourceBundleID: "com.apple.Safari", copied: now,
                                      fingerprint: "abc")
        let data = try JSONEncoder().encode([original])
        #expect(try JSONDecoder().decode([ClipboardEntry].self, from: data) == [original])
        let minimal = #"[{"id":"x","kind":"text","copied":0}]"#
        let decoded = try JSONDecoder().decode([ClipboardEntry].self, from: Data(minimal.utf8))
        #expect(decoded.first?.timesCopied == 1)
        #expect(decoded.first?.pinned == false)
        #expect(decoded.first?.fingerprint == "x")
    }
}

import Foundation
import Testing
@testable import DigUpKit

@Suite struct LauncherProductivityScriptTests {
    static let weather = """
        #!/bin/bash

        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title Weather
        # @raycast.mode compact

        # Optional parameters:
        # @raycast.icon 🌤
        # @raycast.packageName Web
        # @raycast.argument1 { "type": "text", "placeholder": "City", "percentEncoded": true }
        # @raycast.argument2 { "type": "dropdown", "placeholder": "Units", "optional": true, "data": [{"title": "Celsius", "value": "m"}, {"title": "Fahrenheit", "value": "u"}] }
        # @raycast.needsConfirmation true
        # @raycast.currentDirectoryPath ~/Desktop
        # @raycast.refreshTime 10m
        # @raycast.description Today's weather
        # @raycast.author Someone

        curl -s "wttr.in/$1?format=3&$2"
        """

    @Test func parsesEveryField() throws {
        let metadata = try #require(ScriptCommandMetadata.parse(Self.weather))
        #expect(metadata.schemaVersion == 1)
        #expect(metadata.title == "Weather")
        #expect(metadata.mode == .compact)
        #expect(metadata.icon == "🌤")
        #expect(metadata.packageName == "Web")
        #expect(metadata.description == "Today's weather")
        #expect(metadata.needsConfirmation)
        #expect(metadata.currentDirectoryPath == "~/Desktop")
        #expect(metadata.refreshTime == 600)
        #expect(metadata.author == "Someone")
        #expect(metadata.warnings.isEmpty)
        #expect(metadata.arguments.count == 2)
        #expect(metadata.requiredArguments == 1)
        let city = metadata.arguments[0]
        #expect(city.kind == .text && city.placeholder == "City" && city.percentEncoded && !city.optional)
        let units = metadata.arguments[1]
        #expect(units.kind == .dropdown && units.optional)
        #expect(units.options == [.init(title: "Celsius", value: "m"), .init(title: "Fahrenheit", value: "u")])
    }

    @Test func otherCommentMarkers() throws {
        let javascript = "#!/usr/bin/env node\n// @raycast.title Say Hi\n// @raycast.mode silent\nconsole.log('hi')"
        let applescript = "#!/usr/bin/osascript\n-- @raycast.title Play Music\n-- @raycast.mode inline\n"
        #expect(ScriptCommandMetadata.parse(javascript)?.title == "Say Hi")
        #expect(ScriptCommandMetadata.parse(javascript)?.mode == .silent)
        #expect(ScriptCommandMetadata.parse(applescript)?.mode == .inline)
    }

    @Test func withoutATitleItIsNoScriptCommand() {
        #expect(ScriptCommandMetadata.parse("#!/bin/bash\necho hi\n# @raycast.mode compact") == nil)
    }

    @Test func badModeAndArgumentAreWarnings() throws {
        let text = "# @raycast.title X\n# @raycast.mode loud\n# @raycast.argument1 {not json}"
        let metadata = try #require(ScriptCommandMetadata.parse(text))
        #expect(metadata.mode == .fullOutput)
        #expect(metadata.arguments.isEmpty)
        #expect(metadata.warnings.count == 2)
    }

    @Test func percentEncodedArguments() {
        let argument = ScriptArgument(percentEncoded: true)
        #expect(argument.encode("new york & co") == "new%20york%20%26%20co")
        #expect(ScriptArgument().encode("new york") == "new york")
    }

    @Test func typedArgumentsAfterTheTitle() throws {
        let match = try #require(ScriptCommandLine.match("weather berlin", title: "Weather"))
        #expect(match.rest == "berlin")
        #expect(match.score > 0.9)
        let prefix = try #require(ScriptCommandLine.match("wea new york", title: "Weather"))
        #expect(prefix.rest == "new york")
        #expect(ScriptCommandLine.match("weather", title: "Weather")?.rest == "")
        #expect(ScriptCommandLine.match("weather berlin", title: "Weather", takesArguments: false) == nil)
        #expect(ScriptCommandLine.match("zzz berlin", title: "Weather") == nil)
    }

    @Test func splitsArgumentsWithQuotes() {
        #expect(ScriptCommandLine.split("berlin germany", count: 1) == ["berlin germany"])
        #expect(ScriptCommandLine.split("berlin metric extra words", count: 2) == ["berlin", "metric extra words"])
        #expect(ScriptCommandLine.split("\"new york\" metric", count: 2) == ["new york", "metric"])
        #expect(ScriptCommandLine.split("one", count: 3) == ["one"])
        #expect(ScriptCommandLine.split("  ", count: 2) == [])
    }

    @Test func interpreterFromShebangOrExtension() {
        #expect(ScriptCommandLine.interpreter(firstLine: "#!/usr/bin/env python3", pathExtension: "py")
                == ["/usr/bin/env", "python3"])
        #expect(ScriptCommandLine.interpreter(firstLine: "#!/bin/bash -e", pathExtension: "") == ["/bin/bash", "-e"])
        #expect(ScriptCommandLine.interpreter(firstLine: "echo hi", pathExtension: "sh") == ["/bin/bash"])
        #expect(ScriptCommandLine.interpreter(firstLine: nil, pathExtension: "applescript") == ["/usr/bin/osascript"])
        #expect(ScriptCommandLine.interpreter(firstLine: nil, pathExtension: "txt") == nil)
    }

    @Test func outputLastLineWithoutColors() {
        #expect(ScriptCommandLine.lastLine("one\n\u{1B}[1;32mtwo\u{1B}[0m\n\n") == "two")
        #expect(ScriptCommandLine.lastLine("\n \n") == nil)
        #expect(ScriptCommandLine.stripANSI("\u{1B}]0;title\u{07}plain") == "plain")
    }

    @Test func pathPutsHomebrewFirst() {
        #expect(ScriptCommandLine.searchPath(existing: "/usr/bin:/bin:/usr/local/bin")
                == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin")
        #expect(ScriptCommandLine.searchPath(existing: nil).hasSuffix("/usr/bin:/bin:/usr/sbin:/sbin"))
    }

    @Test func intervalsAndFileNames() {
        #expect(ScriptCommandLine.interval("30s") == 30)
        #expect(ScriptCommandLine.interval("1h") == 3600)
        #expect(ScriptCommandLine.interval("soon") == nil)
        #expect(ScriptCommandLine.fileName(forTitle: "Say Hello, World!") == "say-hello-world.sh")
        #expect(ScriptCommandLine.fileName(forTitle: "Café Menu", extension: "py") == "cafe-menu.py")
        #expect(ScriptCommandLine.fileName(forTitle: "!!!") == "script-command.sh")
    }

    @Test func templateParsesBack() throws {
        let metadata = try #require(ScriptCommandMetadata.parse(ScriptCommandLine.template(title: "Say Hello")))
        #expect(metadata.title == "Say Hello")
        #expect(metadata.mode == .compact)
        #expect(metadata.arguments.count == 1 && metadata.arguments[0].optional)
        #expect(metadata.warnings.isEmpty)
    }
}

@Suite struct LauncherProductivityMeetingTests {
    @Test func findsCallLinksInEachField() throws {
        let zoom = try #require(MeetingLinks.find(url: nil, location: "Zoom: https://acme.zoom.us/j/123456789?pwd=abc",
                                                  notes: nil))
        #expect(zoom.service == .zoom)
        #expect(zoom.url.absoluteString == "https://acme.zoom.us/j/123456789?pwd=abc")
        let meet = try #require(MeetingLinks.find(url: nil, location: nil,
                                                  notes: "Join with Google Meet: <https://meet.google.com/abc-defg-hij>."))
        #expect(meet.service == .googleMeet)
        #expect(meet.url.absoluteString == "https://meet.google.com/abc-defg-hij")
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d"
        #expect(MeetingLinks.find(url: teams, location: nil, notes: nil)?.service == .teams)
        #expect(MeetingLinks.find(url: nil, location: "meet.google.com/xyz-abcd-efg", notes: nil)?.service == .googleMeet)
        #expect(MeetingLinks.find(url: nil, location: nil, notes: "[Join](https://whereby.com/team-room)")?.service
                == .whereby)
        #expect(MeetingLinks.find(url: nil, location: nil, notes: "https://facetime.apple.com/join#v=1&p=abc")?.service
                == .faceTime)
        #expect(MeetingLinks.find(url: nil, location: nil, notes: "https://acme.webex.com/meet/jane")?.service == .webex)
        #expect(MeetingLinks.find(url: nil, location: nil, notes: "https://around.co/r/standup")?.service == .around)
    }

    @Test func theURLFieldComesFirst() {
        let link = MeetingLinks.find(url: "https://meet.google.com/aaa-bbbb-ccc", location: "https://zoom.us/j/1",
                                     notes: nil)
        #expect(link?.service == .googleMeet)
    }

    @Test func otherLinksAreNotCalls() {
        #expect(MeetingLinks.find(url: "https://zoom.us/pricing", location: "Room 4",
                                  notes: "Agenda: https://docs.google.com/document/d/1 and https://meet.google.com/")
                == nil)
    }

    @Test func zoomAndTeamsOpenInTheirApps() throws {
        let zoom = MeetingLink(service: .zoom, url: try #require(URL(string: "https://acme.zoom.us/j/987?pwd=s3cret")))
        let native = try #require(zoom.nativeURL)
        #expect(native.scheme == "zoommtg")
        #expect(native.host == "acme.zoom.us")
        let items = URLComponents(url: native, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "confno" }?.value == "987")
        #expect(items.first { $0.name == "pwd" }?.value == "s3cret")
        let vanity = MeetingLink(service: .zoom, url: try #require(URL(string: "https://zoom.us/my/jane")))
        #expect(vanity.nativeURL == nil)
        let teams = MeetingLink(service: .teams,
                                url: try #require(URL(string: "https://teams.microsoft.com/l/meetup-join/abc")))
        #expect(teams.nativeURL?.absoluteString == "msteams://teams.microsoft.com/l/meetup-join/abc")
    }

    @Test func countdownsAndJoinWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ScheduleDay.countdown(start: now.addingTimeInterval(270), end: now.addingTimeInterval(3600), now: now)
                == "In 5 min")
        #expect(ScheduleDay.countdown(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60), now: now)
                == "Now")
        #expect(ScheduleDay.countdown(start: now.addingTimeInterval(4800), end: now.addingTimeInterval(9000), now: now,
                                      within: 7200) == "In 1 h 20 min")
        #expect(ScheduleDay.countdown(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-60), now: now)
                == nil)
        #expect(ScheduleDay.isJoinable(start: now.addingTimeInterval(14 * 60), end: now.addingTimeInterval(3600), now: now))
        #expect(!ScheduleDay.isJoinable(start: now.addingTimeInterval(16 * 60), end: now.addingTimeInterval(3600), now: now))
        #expect(!ScheduleDay.isJoinable(start: now.addingTimeInterval(-3600), end: now, now: now))
    }

    @Test func dayHeadings() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        // Wednesday, October 14, 2026, 09:00 UTC.
        let now = Date(timeIntervalSince1970: 1_791_968_400)
        let day: (Int) -> Date = { now.addingTimeInterval(Double($0) * 86_400) }
        #expect(ScheduleDay.title(for: now, now: now, calendar: calendar, locale: locale) == "Today")
        #expect(ScheduleDay.title(for: day(1), now: now, calendar: calendar, locale: locale) == "Tomorrow")
        #expect(ScheduleDay.title(for: day(2), now: now, calendar: calendar, locale: locale) == "Friday")
        #expect(ScheduleDay.title(for: day(7), now: now, calendar: calendar, locale: locale) == "Wednesday, Oct 21")
    }

    @Test func availabilityBetweenEvents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_968_400)   // Wednesday 09:00
        let hour: (Double) -> Date = { now.addingTimeInterval(($0 - 9) * 3600) }
        let busy = [DateInterval(start: hour(10), end: hour(11)), DateInterval(start: hour(10.5), end: hour(12)),
                    DateInterval(start: hour(12.25), end: hour(13))]
        let slots = ScheduleAvailability.freeSlots(busy: busy, from: now.addingTimeInterval(120), days: 1,
                                                   workStartHour: 9, workEndHour: 17, calendar: calendar)
        // 09:15 (the next quarter hour) to 10:00, then 13:00 to 17:00; 12:00 to 12:15 is too short.
        #expect(slots == [DateInterval(start: hour(9.25), end: hour(10)), DateInterval(start: hour(13), end: hour(17))])
        // Friday and Monday after Thursday: the weekend doesn't count.
        let three = ScheduleAvailability.freeSlots(busy: [], from: now, days: 3, workStartHour: 9, workEndHour: 17,
                                                   calendar: calendar)
        #expect(three.count == 3)
        #expect(calendar.component(.weekday, from: three[2].start) == 6)
        let four = ScheduleAvailability.freeSlots(busy: [], from: now, days: 4, workStartHour: 9, workEndHour: 17,
                                                  calendar: calendar)
        #expect(calendar.component(.weekday, from: four[3].start) == 2)
    }
}

@Suite struct LauncherProductivityFocusTests {
    @Test func domainsMatchThemselvesAndSubdomains() {
        let domains = ["youtube.com", "x.com", "news.ycombinator.com"]
        #expect(FocusDomains.match(host: "youtube.com", domains: domains) == "youtube.com")
        #expect(FocusDomains.match(host: "www.youtube.com", domains: domains) == "youtube.com")
        #expect(FocusDomains.match(host: "M.YouTube.com.", domains: domains) == "youtube.com")
        #expect(FocusDomains.match(host: "notyoutube.com", domains: domains) == nil)
        #expect(FocusDomains.match(host: "box.com", domains: domains) == nil)
        #expect(FocusDomains.match(host: "ycombinator.com", domains: domains) == nil)
        #expect(FocusDomains.blocked(address: "https://www.youtube.com/watch?v=1", domains: domains) == "youtube.com")
        #expect(FocusDomains.blocked(address: "file:///Users/me/blocked.html", domains: domains) == nil)
        #expect(FocusDomains.blocked(address: "https://example.com/youtube.com", domains: domains) == nil)
    }

    @Test func entriesBecomeDomains() {
        #expect(FocusDomains.normalize("https://www.YouTube.com/feed?x=1") == "youtube.com")
        #expect(FocusDomains.normalize("*.reddit.com") == "reddit.com")
        #expect(FocusDomains.normalize(" news.ycombinator.com:443 ") == "news.ycombinator.com")
        #expect(FocusDomains.normalize("hello world") == nil)
        #expect(FocusDomains.normalize("localhost") == nil)
        #expect(FocusDomains.normalize("-bad-.com") == nil)
    }

    @Test func durationsBeforeTheGoal() throws {
        let now = Date(timeIntervalSince1970: 1_791_968_400)   // 09:00 UTC
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parse: (String) -> (seconds: TimeInterval, goal: String)? = {
            FocusDuration.parse($0, now: now, calendar: calendar)
        }
        #expect(try #require(parse("45m write the report")) == (2700, "write the report"))
        #expect(try #require(parse("1h30 taxes")) == (5400, "taxes"))
        #expect(try #require(parse("2 hours 15 min")) == (8100, ""))
        #expect(try #require(parse("25")) == (1500, ""))
        #expect(try #require(parse("until 4:30pm deep work")) == (27000, "deep work"))
        #expect(try #require(parse("until 10:15")) == (4500, ""))
        #expect(parse("3 chapters") == nil)
        #expect(parse("write the report") == nil)
        #expect(parse("30s") == nil)
        #expect(parse("48h") == nil)
    }

    @Test func clockAndDescriptions() {
        #expect(FocusDuration.clock(1122) == "18:42")
        #expect(FocusDuration.clock(65) == "01:05")
        #expect(FocusDuration.clock(3909) == "1:05:09")
        #expect(FocusDuration.clock(0.4) == "00:01")
        #expect(FocusDuration.describe(1500) == "25 minutes")
        #expect(FocusDuration.describe(3600) == "1 hour")
        #expect(FocusDuration.describe(5400) == "1 h 30 min")
    }

    @Test func browserScriptsNameTheirTab() {
        #expect(FocusBrowser.readScript(bundleID: "com.apple.Safari", dialect: .safari).contains("current tab"))
        #expect(FocusBrowser.readScript(bundleID: "com.google.Chrome", dialect: .chromium).contains("active tab"))
        #expect(FocusBrowser.known["company.thebrowser.Browser"]?.dialect == .chromium)
    }
}

@Suite struct LauncherProductivityNotesTests {
    @Test func titleIsTheFirstLineWithText() {
        #expect(NotesText.title(of: "# **Groceries**\n- milk") == "Groceries")
        #expect(NotesText.title(of: "\n\n  Plan for _Monday_  \nmore") == "Plan for Monday")
        #expect(NotesText.title(of: "- [ ] call [Ana](https://example.com)") == "call Ana")
        #expect(NotesText.title(of: "---\n> quoted idea") == "quoted idea")
        #expect(NotesText.title(of: "   \n") == "Untitled Note")
        #expect(NotesText.title(of: "snake_case_name") == "snake_case_name")
        let long = String(repeating: "word ", count: 40)
        #expect(NotesText.title(of: long).count <= NotesText.maxTitleLength + 1)
        #expect(NotesText.title(of: long).hasSuffix("…"))
    }

    @Test func excerptAndSnippet() {
        #expect(NotesText.excerpt(of: "Title\n\n- milk\n- **eggs**") == "milk eggs")
        #expect(NotesText.excerpt(of: "Only a title") == "")
        let text = "The meeting about the quarterly budget is on Friday at the main office, room four."
        let snippet = NotesText.snippet(of: text, matching: "BUDGET", radius: 10)
        #expect(snippet == "…quarterly budget is on…")
        #expect(NotesText.snippet(of: text, matching: "missing") == nil)
    }

    @Test func plainTextDropsMarks() {
        let markdown = "# Title\n\nSome **bold** and `code` with a [link](https://x.y).\n- [ ] task\n- [x] done\n* item\n```\nlet a = b * c\n```"
        #expect(NotesText.plainText(fromMarkdown: markdown)
                == "Title\n\nSome bold and code with a link.\n☐ task\n☑ done\n• item\nlet a = b * c")
    }
}

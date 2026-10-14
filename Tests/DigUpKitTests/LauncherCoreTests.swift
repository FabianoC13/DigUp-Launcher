import Foundation
import Testing
@testable import DigUpKit

@Suite struct FuzzyMatchTests {
    @Test func wholeNameBeatsPrefixBeatsWordPrefix() throws {
        let whole = try #require(FuzzyMatch.score("safari", "Safari"))
        let prefix = try #require(FuzzyMatch.score("saf", "Safari"))
        let word = try #require(FuzzyMatch.score("store", "App Store"))
        #expect(whole == 1)
        #expect(prefix > word)
        #expect(word > 0.75)
    }

    @Test func initialsMatch() throws {
        let score = try #require(FuzzyMatch.score("vsc", "Visual Studio Code"))
        #expect(score >= 0.75 && score < 0.8)
        #expect(FuzzyMatch.score("vsc", "VSCode") != nil)
    }

    @Test func everyWordAPrefix() throws {
        let score = try #require(FuzzyMatch.score("set wi", "Settings: Wi-Fi"))
        #expect(score >= 0.7)
    }

    @Test func accentsAndCaseDontCount() {
        #expect(FuzzyMatch.score("cafe", "Café") == 1)
        #expect(FuzzyMatch.score("CAFE", "café") == 1)
    }

    @Test func lettersInOrderRankTighterHigher() throws {
        let tight = try #require(FuzzyMatch.score("sfri", "Safari"))
        let loose = try #require(FuzzyMatch.score("sfri", "System Information Freeform"))
        #expect(tight > loose)
        #expect(tight < 0.6)
    }

    @Test func noMatchIsNil() {
        #expect(FuzzyMatch.score("xyz", "Safari") == nil)
        #expect(FuzzyMatch.score("", "Safari") == nil)
    }

    @Test func keywordsCountALittleLess() throws {
        let byKeyword = try #require(FuzzyMatch.best("browser", name: "Safari", keywords: ["web browser", "browser"]))
        #expect(byKeyword < 1 && byKeyword > 0.9)
    }
}

@Suite struct LauncherUsageTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func frecencyGrowsWithUseAndFadesWithTime() {
        var usage = LauncherUsage()
        usage.recordUse("app:a", query: "a", at: now)
        let once = usage.frecency("app:a", now: now)
        usage.recordUse("app:a", query: "a", at: now)
        usage.recordUse("app:a", query: "a", at: now)
        let thrice = usage.frecency("app:a", now: now)
        let later = usage.frecency("app:a", now: now.addingTimeInterval(14 * 86_400))
        #expect(thrice > once)
        #expect(abs(later - thrice / 2) < 0.0001)
        #expect(usage.frecency("app:never", now: now) == 0)
    }

    @Test func picksBoostTheExactQueryAndItsPrefixes() {
        var usage = LauncherUsage()
        usage.recordUse("app:safari", query: "saf", at: now)
        #expect(usage.pickBoost("app:safari", query: "saf") >= 0.6)
        let prefix = usage.pickBoost("app:safari", query: "sa")
        #expect(prefix > 0 && prefix < 0.6)
        #expect(usage.pickBoost("app:safari", query: "x") == 0)
        #expect(usage.pickBoost("app:other", query: "saf") == 0)
    }

    @Test func recentIsByFrecency() {
        var usage = LauncherUsage()
        usage.recordUse("a", query: nil, at: now.addingTimeInterval(-30 * 86_400))
        usage.recordUse("b", query: nil, at: now)
        usage.recordUse("b", query: nil, at: now)
        #expect(usage.recent(limit: 5, now: now) == ["b", "a"])
        #expect(usage.recent(limit: 1, now: now) == ["b"])
    }

    @Test func aliasesFavoritesAndForgetting() throws {
        var usage = LauncherUsage()
        usage.aliases["app:safari"] = "web"
        usage.toggleFavorite("app:safari")
        usage.recordUse("app:safari", query: "saf", at: now)
        #expect(usage.item(forAlias: " WEB ") == "app:safari")
        #expect(usage.favorites == ["app:safari"])
        usage.forget("app:safari")
        #expect(usage.item(forAlias: "web") == nil)
        #expect(usage.favorites.isEmpty)
        #expect(usage.records.isEmpty && usage.picks.isEmpty)
    }

    @Test func decodesOlderFilesWithMissingKeys() throws {
        let data = Data(#"{"favorites":["x"]}"#.utf8)
        let usage = try JSONDecoder().decode(LauncherUsage.self, from: data)
        #expect(usage.favorites == ["x"])
        #expect(usage.records.isEmpty)
    }
}

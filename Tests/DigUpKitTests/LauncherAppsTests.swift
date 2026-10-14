import Foundation
import Testing
@testable import DigUpKit

@Suite struct LauncherAppsCatalogTests {
    let home = "/Users/me"

    @Test func infoPlistFlagsInEveryForm() {
        #expect(AppsCatalogRules.isFlagOn(true))
        #expect(AppsCatalogRules.isFlagOn(NSNumber(value: 1)))
        #expect(AppsCatalogRules.isFlagOn("YES"))
        #expect(AppsCatalogRules.isFlagOn("1"))
        #expect(!AppsCatalogRules.isFlagOn("0"))
        #expect(!AppsCatalogRules.isFlagOn(nil))
        #expect(!AppsCatalogRules.isFlagOn(false))
    }

    @Test func agentsOnlyWhenInstalledAndNeverBackgroundOnly() {
        #expect(AppsCatalogRules.shouldList(isUIElement: false, isBackgroundOnly: false, source: .system))
        #expect(AppsCatalogRules.shouldList(isUIElement: true, isBackgroundOnly: false, source: .installed))
        #expect(!AppsCatalogRules.shouldList(isUIElement: true, isBackgroundOnly: false, source: .system))
        #expect(!AppsCatalogRules.shouldList(isUIElement: true, isBackgroundOnly: false, source: .elsewhere))
        #expect(!AppsCatalogRules.shouldList(isUIElement: false, isBackgroundOnly: true, source: .installed))
    }

    @Test func helpersInsideBundlesAreSkippedButXcodesToolsAreNot() {
        #expect(!AppsCatalogRules.isInsideAnotherBundle("/Applications/Safari.app"))
        #expect(!AppsCatalogRules.isInsideAnotherBundle("/Applications/Utilities/Terminal.app"))
        #expect(AppsCatalogRules.isInsideAnotherBundle(
            "/Applications/Google Chrome.app/Contents/Frameworks/Helper.framework/Helpers/Chrome Helper.app"))
        #expect(AppsCatalogRules.isInsideAnotherBundle("/Applications/Foo.app/Contents/Library/LoginItems/Bar.app"))
        #expect(!AppsCatalogRules.isInsideAnotherBundle(
            "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"))
        #expect(!AppsCatalogRules.isInsideAnotherBundle("/Applications/Foo.app/Contents/Applications/Tool.app"))
        // A helper's own helper isn't a tool.
        #expect(AppsCatalogRules.isInsideAnotherBundle(
            "/Applications/Foo.app/Contents/Helpers/Bar.app/Contents/Applications/Baz.app"))
    }

    @Test func spotlightHitsInCachesBuildsAndTheTrashAreSkipped() {
        #expect(!AppsCatalogRules.isExcludedSpotlightPath("/Users/me/Downloads/Tool.app", home: home))
        #expect(!AppsCatalogRules.isExcludedSpotlightPath("/Volumes/Installer/Install Foo.app", home: home))
        #expect(AppsCatalogRules.isExcludedSpotlightPath("/Users/me/Library/Caches/x/Old.app", home: home))
        #expect(AppsCatalogRules.isExcludedSpotlightPath("/Users/me/.Trash/Old.app", home: home))
        #expect(AppsCatalogRules.isExcludedSpotlightPath(
            "/Users/me/Library/Developer/Xcode/DerivedData/P/Build/Products/Debug/App.app", home: home))
        #expect(AppsCatalogRules.isExcludedSpotlightPath("/Users/me/code/x/node_modules/electron/dist/E.app",
                                                         home: home))
        #expect(AppsCatalogRules.isExcludedSpotlightPath("/Users/me/code/.hidden/A.app", home: home))
        #expect(AppsCatalogRules.isExcludedSpotlightPath("/opt/homebrew/Caskroom/a/1/A.app", home: home))
        #expect(AppsCatalogRules.isExcludedSpotlightPath("/System/Volumes/Data/Applications/Safari.app", home: home))
    }

    @Test func applicationsFolderWinsADuplicate() {
        let paths = ["/Users/me/Downloads/Foo.app", "/Volumes/Disk/Foo.app", "/Applications/Foo.app",
                     "/Users/me/Applications/Foo.app"]
        let best = paths.min { AppsCatalogRules.locationRank($0, home: home) < AppsCatalogRules.locationRank($1, home: home) }
        #expect(best == "/Applications/Foo.app")
        #expect(AppsCatalogRules.locationRank("/Users/me/Applications/Foo.app", home: home)
            < AppsCatalogRules.locationRank("/Users/me/Downloads/Foo.app", home: home))
        #expect(AppsCatalogRules.locationRank("/Users/me/Downloads/Foo.app", home: home)
            < AppsCatalogRules.locationRank("/Volumes/Disk/Foo.app", home: home))
    }

    @Test func versionText() {
        #expect(AppsCatalogRules.versionText(short: "17.4", build: "19618.1.15") == "17.4 (19618.1.15)")
        #expect(AppsCatalogRules.versionText(short: "2.0", build: "2.0") == "2.0")
        #expect(AppsCatalogRules.versionText(short: " ", build: "42") == "42")
        #expect(AppsCatalogRules.versionText(short: nil, build: nil) == nil)
    }

    @Test func keywordsAreTheOtherNamesOnceEach() {
        let words = AppsCatalogRules.keywords(name: "Visual Studio Code", bundleName: "Code",
                                              bundleDisplayName: "Visual Studio Code", executable: "Electron",
                                              fileName: "Visual Studio Code.app", bundleID: "com.microsoft.VSCode",
                                              alternateNames: ["Visual Studio Code.app", "code"])
        #expect(words == ["Code", "Electron", "vscode", "vsc"])
        let calendar = AppsCatalogRules.keywords(name: "Calendar", bundleName: "Calendar", fileName: "Calendar.app",
                                                 bundleID: "com.apple.iCal", alternateNames: ["iCal", "Calendar.app"])
        #expect(calendar == ["iCal", "events", "schedule"])
    }

    @Test func initialsCountCamelCase() {
        #expect(AppsCatalogRules.initials("Visual Studio Code") == "vsc")
        #expect(AppsCatalogRules.initials("GarageBand") == "gb")
        #expect(AppsCatalogRules.initials("Safari") == nil)
    }

    @Test func standardFoldersCoverTheSystemAndHome() {
        let folders = AppsCatalogRules.standardFolders(home: home).map(\.path)
        #expect(folders.contains("/Applications"))
        #expect(folders.contains("/Users/me/Applications"))
        #expect(folders.contains("/System/Applications"))
        #expect(folders.contains("/System/Library/CoreServices/Applications"))
        #expect(AppsCatalogRules.coreServicesApps.contains("Finder.app"))
    }
}

@Suite struct LauncherAppsFileSearchTests {
    let home = "/Users/me"

    @Test func libraryHiddenAndDependencyFoldersAreExcluded() {
        #expect(!AppsFileSearchRules.isExcluded("/Users/me/Documents/Budget.xlsx", home: home))
        #expect(!AppsFileSearchRules.isExcluded("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a.txt",
                                                home: home))
        #expect(!AppsFileSearchRules.isExcluded("/Users/me/Library/CloudStorage/Dropbox/a.txt", home: home))
        #expect(AppsFileSearchRules.isExcluded("/Users/me/Library/Preferences/x.plist", home: home))
        #expect(AppsFileSearchRules.isExcluded("/Users/me/.config/x.json", home: home))
        #expect(AppsFileSearchRules.isExcluded("/Users/me/code/app/node_modules/x/readme.md", home: home))
        #expect(AppsFileSearchRules.isExcluded("/Users/me/code/a/build.noindex/x.o", home: home))
        #expect(AppsFileSearchRules.isExcluded("/Users/me/Pictures/Photos Library.photoslibrary/x.jpg", home: home))
        #expect(AppsFileSearchRules.isExcluded("/Applications/Foo.app/Contents/Info.plist", home: home))
        // A bundle itself is a result, only what's inside isn't.
        #expect(!AppsFileSearchRules.isExcluded("/Users/me/Documents/Talk.key", home: home))
    }

    @Test func likePatternsOnePerWordWithWildcardsLiteral() {
        #expect(AppsFileSearchRules.likePatterns(for: "tax  2024") == ["*tax*", "*2024*"])
        #expect(AppsFileSearchRules.likePatterns(for: "a*b?") == [#"*a\*b\?*"#])
    }

    @Test func recencyFavorsOpeningOverChanging() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let opened = AppsFileSearchRules.recency(lastUsed: now, modified: nil, now: now)
        let changed = AppsFileSearchRules.recency(lastUsed: nil, modified: now, now: now)
        let old = AppsFileSearchRules.recency(lastUsed: now.addingTimeInterval(-14 * 86_400), modified: nil, now: now)
        #expect(opened == 1)
        #expect(changed == 0.5)
        #expect(abs(old - 0.5) < 0.0001)
        #expect(AppsFileSearchRules.recency(lastUsed: nil, modified: nil, now: now) == 0)
        // A better name match wins over a fresher file.
        let fresh = AppsFileSearchRules.score(match: 0.6, lastUsed: now, modified: nil, now: now)
        let named = AppsFileSearchRules.score(match: 1, lastUsed: nil, modified: nil, now: now)
        #expect(named > fresh)
    }

    @Test func duplicateNamesLikeFinder() {
        #expect(AppsFileSearchRules.duplicateName(for: "Report.pdf") { _ in false } == "Report copy.pdf")
        let taken: Set = ["Report copy.pdf", "Report copy 2.pdf"]
        #expect(AppsFileSearchRules.duplicateName(for: "Report.pdf") { taken.contains($0) } == "Report copy 3.pdf")
        #expect(AppsFileSearchRules.duplicateName(for: "Folder") { _ in false } == "Folder copy")
    }

    @Test func typedPaths() {
        #expect(AppsFileSearchRules.pathQuery("~/Doc", home: home)! == ("/Users/me", "Doc"))
        #expect(AppsFileSearchRules.pathQuery("~/Documents/", home: home)! == ("/Users/me/Documents", ""))
        #expect(AppsFileSearchRules.pathQuery("~", home: home)! == ("/Users/me", ""))
        #expect(AppsFileSearchRules.pathQuery("/", home: home)! == ("/", ""))
        #expect(AppsFileSearchRules.pathQuery("/App", home: home)! == ("/", "App"))
        #expect(AppsFileSearchRules.pathQuery("/Applications//Util", home: home)! == ("/Applications", "Util"))
        #expect(AppsFileSearchRules.pathQuery("safari", home: home) == nil)
        #expect(AppsFileSearchRules.pathQuery("~me", home: home) == nil)
    }

    @Test func parentFolders() {
        #expect(AppsFileSearchRules.parentQuery(of: "/Users/me/Documents/Work", home: home) == "~/Documents/")
        #expect(AppsFileSearchRules.parentQuery(of: "/Users/me/Documents/", home: home) == "~/")
        #expect(AppsFileSearchRules.parentQuery(of: "/Users/me", home: home) == "/Users/")
        #expect(AppsFileSearchRules.parentQuery(of: "/Applications", home: home) == "/")
        #expect(AppsFileSearchRules.parentQuery(of: "/", home: home) == nil)
        #expect(AppsFileSearchRules.typedPath("/Users/me/Music", home: home) == "~/Music/")
        #expect(AppsFileSearchRules.typedPath("/Users/meg", home: home) == "/Users/meg/")
    }
}

@Suite struct LauncherAppsSettingsPanesTests {
    let battery: [String: Any] = [
        "CFBundleIdentifier": "com.apple.Battery-Settings.extension",
        "CFBundleDisplayName": "PowerPreferences",
        "EXAppExtensionAttributes": [
            "EXExtensionPointIdentifier": "com.apple.Settings.extension.ui",
            "SettingsExtensionAttributes": [
                "allowsXAppleSystemPreferencesURLScheme": true,
                "searchTermsFileName": "PowerPreferences",
                "representations": [
                    ["predicate": "powersource.battery != YES", "sidebar-name": "ENERGY_SAVER_PREF_TITLE",
                     "sidebar-iconUTTypeIdentifier": "com.apple.graphic-icon.energy"],
                    ["predicate": "powersource.battery == YES", "sidebar-name": "BATTERY_PREF_TITLE",
                     "sidebar-iconUTTypeIdentifier": "com.apple.graphic-icon.battery"],
                ],
            ] as [String: Any],
        ] as [String: Any],
    ]

    @Test func readsAPanesInfoPlist() throws {
        let info = try #require(AppsSettingsPanes.info(fromInfoPlist: battery))
        #expect(info.bundleID == "com.apple.Battery-Settings.extension")
        #expect(info.opensByURL)
        #expect(info.searchTermsFile == "PowerPreferences")
        #expect(info.representations.count == 2)
        #expect(info.representations[1].sidebarName == "BATTERY_PREF_TITLE")
        #expect(info.representations[1].iconType == "com.apple.graphic-icon.battery")
        let notAPane: [String: Any] = ["CFBundleIdentifier": "x", "EXAppExtensionAttributes":
            ["EXExtensionPointIdentifier": "com.apple.quicklook.thumbnail"]]
        #expect(AppsSettingsPanes.info(fromInfoPlist: notAPane) == nil)
    }

    @Test func predicates() {
        let facts = ["powersource.battery": true, "device.trackpad": false]
        #expect(AppsSettingsPanes.evaluate("powersource.battery == YES", facts: facts) == true)
        #expect(AppsSettingsPanes.evaluate("powersource.battery != YES", facts: facts) == false)
        #expect(AppsSettingsPanes.evaluate("device.trackpad == NO", facts: facts) == true)
        #expect(AppsSettingsPanes.evaluate("device.mouse == YES", facts: facts) == nil)
        #expect(AppsSettingsPanes.evaluate("a == YES && b == NO", facts: facts) == nil)
    }

    @Test func choosesTheRepresentationThisMacShows() throws {
        let info = try #require(AppsSettingsPanes.info(fromInfoPlist: battery))
        let laptop = AppsSettingsPanes.choose(info.representations, facts: ["powersource.battery": true])
        #expect(laptop.visible && laptop.representation?.sidebarName == "BATTERY_PREF_TITLE")
        let desktop = AppsSettingsPanes.choose(info.representations, facts: ["powersource.battery": false])
        #expect(desktop.visible && desktop.representation?.sidebarName == "ENERGY_SAVER_PREF_TITLE")
        let trackpad = [AppsSettingsPanes.Representation(predicate: "device.trackpad == YES", hidden: false),
                        AppsSettingsPanes.Representation(predicate: "device.trackpad != YES", hidden: true)]
        #expect(!AppsSettingsPanes.choose(trackpad, facts: ["device.trackpad": false]).visible)
        #expect(AppsSettingsPanes.choose(trackpad, facts: ["device.trackpad": true]).visible)
        // Not knowing is showing: better a pane too many than one missing.
        #expect(AppsSettingsPanes.choose(trackpad, facts: [:]).visible)
        #expect(AppsSettingsPanes.choose([], facts: [:]).visible)
    }

    @Test func namesSettingsShowsNotBundleNames() {
        #expect(AppsSettingsPanes.displayName(sidebarName: "Battery", localizedDisplayName: "PowerPreferences",
                                              knownName: nil, infoDisplayName: nil, infoName: nil,
                                              fileName: "PowerPreferences.appex") == "Battery")
        #expect(AppsSettingsPanes.displayName(sidebarName: nil, localizedDisplayName: "Wi\u{2011}Fi", knownName: nil,
                                              infoDisplayName: "WiFiSettings", infoName: nil,
                                              fileName: "Wi-Fi.appex") == "Wi-Fi")
        #expect(AppsSettingsPanes.displayName(sidebarName: "BATTERY_PREF_TITLE", localizedDisplayName: nil,
                                              knownName: "Battery", infoDisplayName: nil, infoName: nil,
                                              fileName: "x.appex") == "Battery")
        #expect(AppsSettingsPanes.displayName(sidebarName: nil, localizedDisplayName: nil, knownName: nil,
                                              infoDisplayName: "DisplaysExt", infoName: nil,
                                              fileName: "StartupDiskSettings.appex") == "Startup Disk")
        #expect(AppsSettingsPanes.looksInternal("CoverageSettingPane_macOS"))
        #expect(AppsSettingsPanes.looksInternal("UsersGroups"))
        #expect(!AppsSettingsPanes.looksInternal("Printers & Scanners"))
    }

    @Test func searchTermsFromAPanesFile() {
        let plist: [String: Any] = [
            "balance": ["localizableStrings": [["title": "Output balance", "index": "headphones, speakers, balance"]]],
            "mute": ["localizableStrings": [["title": "Mute the sound", "index": "quiet, silent, Headphones"]]],
        ]
        let terms = AppsSettingsPanes.searchTerms(fromPlist: plist)
        #expect(terms == ["Output balance", "headphones", "speakers", "balance", "Mute the sound", "quiet", "silent"])
        #expect(AppsSettingsPanes.searchTerms(fromPlist: plist, limit: 2).count == 2)
    }

    @Test func searchTermsNeedAWordStartAndThreeLetters() throws {
        let terms = ["louder", "headphones", "mute the sound"]
        #expect(AppsSettingsPanes.score("lo", name: "Sound", keywords: [], searchTerms: terms) == nil)
        let byTerm = try #require(AppsSettingsPanes.score("head", name: "Sound", keywords: [], searchTerms: terms))
        let byName = try #require(AppsSettingsPanes.score("sou", name: "Sound", keywords: [], searchTerms: terms))
        #expect(byName > byTerm)
        #expect(AppsSettingsPanes.score("eadph", name: "Sound", keywords: [], searchTerms: terms) == nil)
    }

    @Test func linksAndTables() {
        #expect(AppsSettingsPanes.url(for: "com.apple.wifi-settings-extension")
            == "x-apple.systempreferences:com.apple.wifi-settings-extension")
        #expect(AppsSettingsPanes.url(for: AppsSettingsPanes.privacyPane, anchor: "Privacy_AllFiles")
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        #expect(AppsSettingsPanes.known["com.apple.wifi-settings-extension"]?.iconType
            == "com.apple.graphic-icon.wifi")
        let fallback = AppsSettingsPanes.fallbackPanes
        #expect(fallback.contains { $0.name == "Wi-Fi" })
        #expect(!fallback.contains { AppsSettingsPanes.hiddenPanes.contains($0.bundleID) })
        #expect(Set(AppsSettingsPanes.privacyAnchors.map(\.anchor)).count == AppsSettingsPanes.privacyAnchors.count)
    }
}

@Suite struct LauncherAppsPreferencesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func decodesOlderFilesWithDefaults() throws {
        let prefs = try JSONDecoder().decode(AppsPreferences.self, from: Data(#"{"extraFolders":["~/Apps"]}"#.utf8))
        #expect(prefs.extraFolders == ["~/Apps"])
        #expect(prefs.filesInRootSearch)
        #expect(!prefs.autoQuitEnabled)
        #expect(prefs.autoQuitMinutes == AppsAutoQuit.defaultMinutes)
        let again = try JSONDecoder().decode(AppsPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(again == prefs)
    }

    @Test func autoQuitListAndFolders() {
        var prefs = AppsPreferences()
        prefs.setAutoQuit(bundleID: "com.a", name: "A", minutes: nil)
        prefs.setAutoQuit(bundleID: "com.b", name: "B", minutes: 10)
        prefs.setAutoQuit(bundleID: "com.a", name: "A", minutes: 5)
        #expect(prefs.autoQuitApps.map(\.bundleID) == ["com.a", "com.b"])
        #expect(prefs.autoQuitRule(for: "com.a")?.minutes == 5)
        prefs.removeAutoQuit(bundleID: "com.a")
        #expect(prefs.autoQuitRule(for: "com.a") == nil)
        let added = prefs.addExtraFolder("/Users/me/Apps/")
        let addedAgain = prefs.addExtraFolder("/Users/me/Apps")
        #expect(added && !addedAgain)
        #expect(prefs.extraFolders == ["/Users/me/Apps"])
    }

    @Test func dueAfterTheirMinutesInTheBackground() {
        let rules = [AppsAutoQuitRule(bundleID: "com.a", name: "A"),
                     AppsAutoQuitRule(bundleID: "com.b", name: "B", minutes: 10)]
        let watched = now.addingTimeInterval(-3600)
        let running = [AppsAutoQuit.RunningApp(bundleID: "com.a", lastActive: now.addingTimeInterval(-4 * 60)),
                       AppsAutoQuit.RunningApp(bundleID: "com.b", lastActive: now.addingTimeInterval(-4 * 60)),
                       AppsAutoQuit.RunningApp(bundleID: "com.c", lastActive: nil)]
        func due(frontmost: String? = nil, paused: Set<String> = [], asked: [String: Date] = [:],
                 since: Date? = nil) -> [String] {
            AppsAutoQuit.due(running: running, rules: rules, defaultMinutes: 3, frontmost: frontmost, paused: paused,
                             asked: asked, watchedSince: since ?? watched, now: now)
        }
        #expect(due() == ["com.a"])
        #expect(due(frontmost: "com.a").isEmpty)
        #expect(due(paused: ["com.a"]).isEmpty)
        // Asked a minute ago and still running (it asked about unsaved work): not again yet.
        #expect(due(asked: ["com.a": now.addingTimeInterval(-60)]).isEmpty)
        // Auto Quit was just turned on: the clocks start now.
        #expect(due(since: now.addingTimeInterval(-60)).isEmpty)
    }

    @Test func neverQuitsFinderAndAppsWithoutARule() {
        let rules = [AppsAutoQuitRule(bundleID: "com.apple.finder", name: "Finder", minutes: 1)]
        let running = [AppsAutoQuit.RunningApp(bundleID: "com.apple.finder", lastActive: nil),
                       AppsAutoQuit.RunningApp(bundleID: "com.other", lastActive: nil)]
        #expect(AppsAutoQuit.due(running: running, rules: rules, defaultMinutes: 3, frontmost: nil, paused: [],
                                 asked: [:], watchedSince: now.addingTimeInterval(-86_400), now: now).isEmpty)
    }

    @Test func durationText() {
        #expect(AppsAutoQuit.durationText(1) == "1 minute")
        #expect(AppsAutoQuit.durationText(15) == "15 minutes")
        #expect(AppsAutoQuit.durationText(60) == "1 hour")
        #expect(AppsAutoQuit.durationText(120) == "2 hours")
    }
}

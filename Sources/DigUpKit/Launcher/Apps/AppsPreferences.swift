import Foundation

/// The launcher's Applications settings, saved as JSON: folders scanned for apps besides the standard ones, whether
/// files by name show in root search, and Auto Quit.
public struct AppsPreferences: Codable, Equatable, Sendable {
    /// Folders scanned for apps besides /Applications, ~/Applications and the system's ("~/Developer/Apps").
    public var extraFolders: [String] = []
    /// Files whose names match show below the other results in root search.
    public var filesInRootSearch = true
    /// Auto Quit runs at all (off by default).
    public var autoQuitEnabled = false
    /// Minutes in the background before an app on the list quits, unless it has its own.
    public var autoQuitMinutes = AppsAutoQuit.defaultMinutes
    /// The apps Auto Quit quits, in the order they were added.
    public var autoQuitApps: [AppsAutoQuitRule] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case extraFolders, filesInRootSearch, autoQuitEnabled, autoQuitMinutes, autoQuitApps
    }

    /// Older files may lack newer keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extraFolders = try container.decodeIfPresent([String].self, forKey: .extraFolders) ?? []
        filesInRootSearch = try container.decodeIfPresent(Bool.self, forKey: .filesInRootSearch) ?? true
        autoQuitEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoQuitEnabled) ?? false
        autoQuitMinutes = try container.decodeIfPresent(Int.self, forKey: .autoQuitMinutes)
            ?? AppsAutoQuit.defaultMinutes
        autoQuitApps = try container.decodeIfPresent([AppsAutoQuitRule].self, forKey: .autoQuitApps) ?? []
    }

    /// The Auto Quit rule for an app, if it's on the list.
    public func autoQuitRule(for bundleID: String) -> AppsAutoQuitRule? {
        autoQuitApps.first { $0.bundleID == bundleID }
    }

    /// Puts an app on the Auto Quit list (or changes its minutes when it's there already; nil: the default).
    public mutating func setAutoQuit(bundleID: String, name: String, minutes: Int?) {
        if let index = autoQuitApps.firstIndex(where: { $0.bundleID == bundleID }) {
            autoQuitApps[index].minutes = minutes
            autoQuitApps[index].name = name
        } else {
            autoQuitApps.append(AppsAutoQuitRule(bundleID: bundleID, name: name, minutes: minutes))
        }
    }

    public mutating func removeAutoQuit(bundleID: String) {
        autoQuitApps.removeAll { $0.bundleID == bundleID }
    }

    /// Adds a folder to scan, once; false when it was there already.
    @discardableResult
    public mutating func addExtraFolder(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard !extraFolders.contains(where: { ($0 as NSString).standardizingPath == standardized }) else {
            return false
        }
        extraFolders.append(standardized)
        return true
    }
}

/// An app Auto Quit quits once it has been in the background long enough.
public struct AppsAutoQuitRule: Codable, Equatable, Sendable, Identifiable {
    public var bundleID: String
    /// Its name when it was added, for Settings while it isn't installed or running.
    public var name: String
    /// Its own minutes; nil: the default.
    public var minutes: Int?

    public var id: String { bundleID }

    public init(bundleID: String, name: String, minutes: Int? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.minutes = minutes
    }
}

/// Auto Quit (like Raycast's): apps you choose quit by themselves once they've been in the background for a while.
/// Being in front resets an app's clock; the launcher only asks it to quit, so an app with unsaved work asks you first.
public enum AppsAutoQuit {
    public static let defaultMinutes = 3
    /// The choices Settings and the action panel offer.
    public static let durations = [1, 3, 5, 10, 15, 30, 60]
    /// Apps it never quits, whatever the list says: Finder (it relaunches at once) and DigUp itself.
    public static let neverQuit: Set<String> = ["com.apple.finder", "com.apple.loginwindow", "com.abdurrahim.DigUp"]
    /// Players whose clocks stop while sound is playing (quitting them would stop the music).
    public static let players: Set<String> = ["com.apple.Music", "com.spotify.client", "com.apple.podcasts",
                                              "com.apple.TV", "com.tidal.desktop", "com.apple.QuickTimePlayerX"]

    /// One app that's running now: its bundle id and when it was last in front (nil: not since the launcher started
    /// watching, which counts from `watchedSince`).
    public struct RunningApp: Sendable {
        public let bundleID: String
        public let lastActive: Date?

        public init(bundleID: String, lastActive: Date?) {
            self.bundleID = bundleID
            self.lastActive = lastActive
        }
    }

    /// The bundle ids to ask to quit now: on the list, not in front, not paused (`paused`: recording, or a player
    /// playing), and in the background for at least their minutes. `asked` holds when each was last asked, so an app
    /// that declined (unsaved work) isn't asked again before another full period.
    public static func due(running: [RunningApp], rules: [AppsAutoQuitRule], defaultMinutes: Int, frontmost: String?,
                           paused: Set<String>, asked: [String: Date], watchedSince: Date, now: Date) -> [String] {
        var minutesByID: [String: Int] = [:]
        for rule in rules { minutesByID[rule.bundleID] = max(1, rule.minutes ?? defaultMinutes) }
        var due: [String] = []
        for app in running {
            guard let minutes = minutesByID[app.bundleID], app.bundleID != frontmost,
                  !neverQuit.contains(app.bundleID), !paused.contains(app.bundleID) else { continue }
            let period = TimeInterval(minutes * 60)
            var since = max(app.lastActive ?? watchedSince, watchedSince)
            if let last = asked[app.bundleID] { since = max(since, last) }
            if now.timeIntervalSince(since) >= period { due.append(app.bundleID) }
        }
        return due
    }

    /// "1 minute", "3 minutes", "1 hour".
    public static func durationText(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

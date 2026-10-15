import Foundation

/// Which app bundles the launcher lists, under which names, and which copy wins when an app is installed twice.
///
/// Pure rules over paths and Info.plist values, so they can be tested without the disk; the app's scanner reads the
/// bundles and asks these.
public enum AppsCatalogRules {
    /// Where a bundle was found, which decides how strict the listing is.
    public enum Source: Sendable, Equatable {
        /// /Applications, ~/Applications and the folders added in Settings: apps you installed. Menu bar apps
        /// (LSUIElement) are listed, since opening one is how you start it.
        case installed
        /// /System/Applications and /System/Library/CoreServices: only apps with a window.
        case system
        /// Spotlight found it somewhere else (a disk image, ~/Downloads): only apps with a window.
        case elsewhere
    }

    /// The folders scanned for apps, with how deep to look (packages are never entered). `home` is the user's home.
    public static func standardFolders(home: String) -> [(path: String, depth: Int, source: Source)] {
        [
            ("/Applications", 4, .installed),
            (home + "/Applications", 4, .installed),
            ("/System/Applications", 2, .system),
            ("/System/Library/CoreServices/Applications", 1, .system),
        ]
    }

    /// Apps at the top of /System/Library/CoreServices worth launching by name; the rest there are agents and helpers.
    public static let coreServicesApps: Set<String> = [
        "Finder.app", "Certificate Assistant.app", "AVB Configuration.app", "Accessibility Reader.app",
    ]

    /// Folders inside an app bundle whose apps are tools of their own (Xcode's Simulator, Instruments, FileMerge).
    static let toolFolders = ["/Contents/Applications/", "/Contents/Developer/Applications/"]

    /// Whether a bundle's LSUIElement / LSBackgroundOnly value is on: Info.plists spell it as a boolean, a number or a
    /// string ("1", "YES", "true").
    public static func isFlagOn(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return ["1", "yes", "true"].contains(text.lowercased())
        default: return false
        }
    }

    /// Whether an app found in `source` goes in the list: background-only apps never do, and agents (no Dock icon,
    /// LSUIElement) only when you installed them yourself.
    public static func shouldList(isUIElement: Bool, isBackgroundOnly: Bool, source: Source) -> Bool {
        if isBackgroundOnly { return false }
        if isUIElement { return source == .installed }
        return true
    }

    /// Whether the bundle sits inside another app's bundle (a helper, an updater, a login item), except for the tool
    /// folders apps like Xcode ship their own launchable apps in.
    public static func isInsideAnotherBundle(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard containsPackage(parent) else { return false }
        for folder in toolFolders {
            guard let range = path.range(of: folder, options: .backwards) else { continue }
            let host = String(path[..<range.lowerBound])
            let rest = String(path[range.upperBound...])
            // The tool app is directly in the folder, and its host is a top-level app (not a helper's helper).
            if !rest.dropLast(rest.hasSuffix("/") ? 1 : 0).contains("/"), !containsPackage(
                (host as NSString).deletingLastPathComponent) {
                return false
            }
        }
        return true
    }

    /// Whether some component of `path` is a bundle (".app", ".framework", ".appex"…).
    static func containsPackage(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            let ext = (String(component) as NSString).pathExtension.lowercased()
            return packageExtensions.contains(ext)
        }
    }

    static let packageExtensions: Set<String> = [
        "app", "framework", "appex", "bundle", "plugin", "xpc", "kext", "systemextension", "prefpane", "qlgenerator",
        "mdimporter", "saver", "wdgt", "dext",
    ]

    /// Places Spotlight reports apps in that aren't apps you'd launch: caches, build products, the Trash, other
    /// tools' private copies, simulators' disks, package managers' stores.
    public static func isExcludedSpotlightPath(_ path: String, home: String) -> Bool {
        let excludedPrefixes = [
            "/System/Volumes/", "/private/", "/usr/", "/opt/", "/bin/", "/sbin/", "/Library/",
            "/System/Library/", "/System/iOSSupport/", "/System/Cryptexes/", "/nix/",
            home + "/Library/", home + "/.Trash/",
        ]
        if excludedPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        let excludedComponents: Set<String> = [
            "node_modules", "DerivedData", "Caches", ".Trash", ".Trashes", "Caskroom", "Cellar", "build.noindex",
            "Build", "Intermediates.noindex", "Products", "Pods", "vendor", "site-packages",
        ]
        return path.split(separator: "/").dropLast().contains { component in
            component.hasPrefix(".") || excludedComponents.contains(String(component))
                || component.hasSuffix(".noindex")
        }
    }

    /// Lower is preferred when the same app (same bundle id) is in two places: /Applications first, then the system
    /// folders, ~/Applications, added folders, then anywhere else.
    public static func locationRank(_ path: String, home: String) -> Int {
        if path.hasPrefix("/Applications/") { return 0 }
        if path.hasPrefix("/System/Applications/") { return 1 }
        if path.hasPrefix("/System/Library/CoreServices/") { return 2 }
        if path.hasPrefix(home + "/Applications/") { return 3 }
        if path.hasPrefix("/Volumes/") { return 6 }
        if path.hasPrefix(home + "/") { return 4 }
        return 5
    }

    /// "17.4 (19618.1.15)", "17.4", or nil.
    public static func versionText(short: String?, build: String?) -> String? {
        let short = short.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let build = build.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        switch (short, build) {
        case let (short?, build?) where short != build: return "\(short) (\(build))"
        case let (short?, _): return short
        case let (nil, build?): return build
        default: return nil
        }
    }

    /// Other names an app answers to besides `name` (its display name): the names in its Info.plist, its executable,
    /// its file name, Spotlight's alternate names ("iCal" for Calendar), descriptive words for well-known apps
    /// ("browser"), and its initials ("vsc" for Visual Studio Code). Each once, never the name itself.
    public static func keywords(name: String, bundleName: String? = nil, bundleDisplayName: String? = nil,
                                executable: String? = nil, fileName: String? = nil, bundleID: String? = nil,
                                alternateNames: [String] = []) -> [String] {
        var seen: Set<String> = [FuzzyMatch.normalize(name)]
        var result: [String] = []
        func add(_ candidate: String?) {
            guard var candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty
            else { return }
            if candidate.lowercased().hasSuffix(".app") { candidate = String(candidate.dropLast(4)) }
            let key = FuzzyMatch.normalize(candidate)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            result.append(candidate)
        }
        add(bundleDisplayName)
        add(bundleName)
        add(fileName)
        add(executable)
        for alternate in alternateNames { add(alternate) }
        if let bundleID { for word in descriptiveKeywords[bundleID] ?? [] { add(word) } }
        add(initials(name))
        return result
    }

    /// The first letters of a name's words, camel case counting ("Visual Studio Code" → "vsc", "GarageBand" → "gb"); nil
    /// for a one-word name.
    public static func initials(_ name: String) -> String? {
        let words = FuzzyMatch.words(name, splittingCamelCase: true)
        guard words.count >= 2 else { return nil }
        return String(words.compactMap(\.first)).lowercased()
    }

    /// What people type for well-known apps, besides their names (Spotlight's alternate names cover the old names).
    public static let descriptiveKeywords: [String: [String]] = [
        "com.apple.Safari": ["browser", "web"],
        "com.google.Chrome": ["browser", "web"],
        "company.thebrowser.Browser": ["browser", "web"],
        "org.mozilla.firefox": ["browser", "web"],
        "com.brave.Browser": ["browser", "web"],
        "com.microsoft.edgemac": ["browser", "web"],
        "com.apple.Terminal": ["shell", "console", "command line"],
        "com.googlecode.iterm2": ["terminal", "shell"],
        "com.mitchellh.ghostty": ["terminal", "shell"],
        "com.apple.ActivityMonitor": ["task manager", "processes", "cpu", "memory"],
        "com.apple.finder": ["files", "explorer"],
        "com.apple.mail": ["email", "inbox"],
        "com.apple.MobileSMS": ["sms", "imessage", "chat"],
        "com.apple.iCal": ["events", "schedule"],
        "com.apple.reminders": ["todo", "tasks"],
        "com.apple.Notes": ["notepad"],
        "com.apple.TextEdit": ["notepad", "text editor"],
        "com.apple.Preview": ["pdf", "images"],
        "com.apple.calculator": ["calc"],
        "com.apple.DiskUtility": ["format", "partition", "disks"],
        "com.apple.Console": ["logs"],
        "com.apple.keychainaccess": ["passwords", "certificates"],
        "com.apple.Passwords": ["keychain", "logins"],
        "com.apple.AppStore": ["store", "mac app store"],
        "com.apple.QuickTimePlayerX": ["video", "movie", "screen recording"],
        "com.apple.screenshot.launcher": ["screen capture", "screen recording"],
        "com.apple.Photos": ["pictures", "images"],
        "com.apple.PhotoBooth": ["camera", "webcam"],
        "com.apple.Music": ["songs", "itunes"],
        "com.apple.systempreferences": ["settings", "preferences", "control panel"],
        "com.apple.ScriptEditor2": ["applescript"],
        "com.apple.freeform": ["whiteboard"],
        "com.apple.SystemProfiler": ["about this mac", "hardware"],
        "com.apple.archiveutility": ["unzip", "zip"],
        "com.microsoft.VSCode": ["vscode", "code"],
        "com.todesktop.230313mzl4w4u92": ["code editor", "ide"],
        "com.apple.dt.Xcode": ["ide"],
        "com.spotify.client": ["music"],
        "us.zoom.xos": ["meeting", "video call"],
    ]
}

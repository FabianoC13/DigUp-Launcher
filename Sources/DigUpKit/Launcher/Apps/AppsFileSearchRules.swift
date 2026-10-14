import Foundation

/// Finding files by name in Spotlight's index, like Raycast's File Search: which hits to drop, how to ask Spotlight,
/// and how to rank what comes back.
public enum AppsFileSearchRules {
    /// Fewer characters match too much to be worth asking Spotlight.
    public static let minimumQueryLength = 2

    /// Hits that aren't your files: ~/Library (except iCloud Drive and cloud storage folders), hidden files and
    /// folders, caches, dependency and build folders, anything inside a bundle (an app's resources, a library's
    /// photos).
    public static func isExcluded(_ path: String, home: String) -> Bool {
        let library = home + "/Library/"
        if path.hasPrefix(library) {
            let kept = [library + "Mobile Documents/", library + "CloudStorage/"]
            guard kept.contains(where: { path.hasPrefix($0) }) else { return true }
        }
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            if component.hasPrefix(".") { return true }
            let isLast = index == components.count - 1
            if !isLast {
                if excludedFolders.contains(component) || component.hasSuffix(".noindex") { return true }
                if packageExtensions.contains((component as NSString).pathExtension.lowercased()) { return true }
            }
        }
        return false
    }

    static let excludedFolders: Set<String> = [
        "node_modules", "Caches", "DerivedData", "__pycache__", "bower_components", ".build", "Pods",
    ]

    /// Folders that are documents or bundles in Finder: what's inside them isn't a result of its own.
    static let packageExtensions: Set<String> = [
        "app", "framework", "appex", "bundle", "plugin", "xpc", "kext", "photoslibrary", "musiclibrary", "tvlibrary",
        "photolibrary", "imovielibrary", "fcpbundle", "logicx", "band", "xcarchive", "xcodeproj", "xcworkspace",
        "playground", "rtfd", "pages", "numbers", "key", "sparsebundle", "dsym", "lproj", "scptd", "docarchive",
    ]

    /// The words of the query, each as a Spotlight LIKE pattern that finds it anywhere in a name ("*budget*"), with
    /// Spotlight's wildcards in what you typed taken literally.
    public static func likePatterns(for query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { word in
            var escaped = ""
            for character in word {
                if character == "*" || character == "?" || character == "\\" { escaped.append("\\") }
                escaped.append(character)
            }
            return "*" + escaped + "*"
        }
    }

    /// 0…1: how lately the file was opened (or, never opened, changed). Halves every `halfLifeDays`; a change counts
    /// half as much as an opening.
    public static func recency(lastUsed: Date?, modified: Date?, now: Date) -> Double {
        func decay(_ date: Date) -> Double {
            let days = max(0, now.timeIntervalSince(date) / 86_400)
            return pow(0.5, days / halfLifeDays)
        }
        let used = lastUsed.map(decay) ?? 0
        let changed = modified.map(decay).map { $0 * 0.5 } ?? 0
        return max(used, changed)
    }

    public static let halfLifeDays = 14.0

    /// A hit's rank: mostly how well its name matches, then how lately it was used.
    public static func score(match: Double, lastUsed: Date?, modified: Date?, now: Date) -> Double {
        0.8 * match + 0.2 * recency(lastUsed: lastUsed, modified: modified, now: now)
    }

    /// A typed path, as a folder to list and the start of a name in it: "~/Doc" → (home, "Doc"), "/Applications/" →
    /// ("/Applications", ""), "~" → (home, ""). Nil when what's typed isn't a path (it starts with neither "/" nor
    /// "~/").
    public static func pathQuery(_ text: String, home: String) -> (folder: String, prefix: String)? {
        var path = text.trimmingCharacters(in: .whitespaces)
        if path == "~" { return (home, "") }
        if path.hasPrefix("~/") {
            path = home + path.dropFirst()
        } else if !path.hasPrefix("/") {
            return nil
        }
        // "//" typed by accident is one slash, as in Finder's Go to Folder.
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
        if path.hasSuffix("/") {
            let folder = path == "/" ? "/" : String(path.dropLast())
            return (folder, "")
        }
        let slash = path.lastIndex(of: "/")!
        let folder = slash == path.startIndex ? "/" : String(path[..<slash])
        return (folder, String(path[path.index(after: slash)...]))
    }

    /// The folder above `path` as a path to type, ending in "/" ("~/Documents/Work" → "~/Documents/"), with the home
    /// folder as "~". Nil at the top ("/").
    public static func parentQuery(of path: String, home: String) -> String? {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return nil }
        let parent = slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
        return typedPath(parent, home: home)
    }

    /// A folder as you'd type it to list it: "~/Documents/", "/Applications/", "/".
    public static func typedPath(_ folder: String, home: String) -> String {
        if folder == "/" { return "/" }
        if folder == home { return "~/" }
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) + "/" }
        return folder + "/"
    }

    /// A free name for a copy next to the original, the way Finder names them: "Report copy.pdf", then
    /// "Report copy 2.pdf"… `taken` says whether a name is already used in the folder.
    public static func duplicateName(for name: String, taken: (String) -> Bool) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        func named(_ stem: String) -> String { ext.isEmpty ? stem : stem + "." + ext }
        var candidate = named(base + " copy")
        var number = 2
        while taken(candidate) {
            candidate = named("\(base) copy \(number)")
            number += 1
        }
        return candidate
    }
}

import AppKit
import CoreServices
import DigUpKit

/// One app the launcher lists: what it shows and what it matches against. Read off the main thread.
nonisolated struct AppsEntry: Sendable, Hashable {
    let path: String
    /// The name Finder shows (localized: "Calculadora" in Portuguese), without ".app".
    let name: String
    /// Its other names: Info.plist names, executable, file name, Spotlight's alternate names ("iCal"), initials.
    let keywords: [String]
    let bundleID: String?
    /// "17.4 (19618.1.15)".
    let version: String?

    var url: URL { URL(fileURLWithPath: path) }
    /// macOS's own apps (on the sealed system volume): they can't be moved to the Trash.
    var isSystem: Bool { path.hasPrefix("/System/") }
}

/// Every app on this Mac: the standard folders and the ones added in Settings, scanned off the main thread, plus the
/// apps Spotlight knows of elsewhere (Downloads, a mounted disk). Rescans when an app folder changes (FSEvents), when
/// an app it doesn't know launches, and every few minutes.
final class AppsCatalog {
    private(set) var entries: [AppsEntry] = []
    private var byPath: [String: AppsEntry] = [:]
    private var byBundleID: [String: AppsEntry] = [:]
    /// Apps outside the scanned folders, from Spotlight.
    private var spotlightPaths: [String] = []
    private var extraFolders: [String] = []
    private var query: NSMetadataQuery?
    private var watcher: FolderWatcher?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var scanning = false
    private var rescanPending = false
    private var rescanTask: Task<Void, Never>?
    /// Launched apps a rescan didn't list (a translocated download, a helper): they don't trigger another.
    private var unlistedLaunches = Set<String>()
    /// The first scan is done.
    private(set) var isReady = false

    static let rescanInterval: TimeInterval = 10 * 60

    func start(extraFolders: [String]) {
        self.extraFolders = extraFolders
        scan()
        startSpotlight()
        watchFolders()
        timer = Timer.scheduledTimer(withTimeInterval: Self.rescanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        timer?.tolerance = 60
        // An app it doesn't know started (installed somewhere it doesn't watch, or just now): look again.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let path = app?.bundleURL?.path
            let regular = app?.activationPolicy == .regular
            MainActor.assumeIsolated {
                guard let self, regular, let path, self.byPath[path] == nil,
                      self.unlistedLaunches.insert(path).inserted else { return }
                self.scheduleRescan(after: .seconds(1))
            }
        })
        // A disk with apps on it came or went.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRescan(after: .seconds(3)) }
            })
        }
    }

    /// The folders added in Settings changed.
    func setExtraFolders(_ folders: [String]) {
        extraFolders = folders
        watchFolders()
        scheduleRescan(after: .zero)
    }

    func entry(path: String) -> AppsEntry? { byPath[path] }
    func entry(bundleID: String) -> AppsEntry? { byBundleID[bundleID] }

    /// Scans again after `delay`, once however many times it's asked meanwhile.
    func scheduleRescan(after delay: Duration = .seconds(2)) {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    /// Reads every app folder and Spotlight's extra apps off the main thread, then swaps the list in.
    private func scan() {
        if scanning {
            rescanPending = true
            return
        }
        scanning = true
        let folders = extraFolders
        let elsewhere = spotlightPaths
        let started = Date()
        Task {
            let found = await Task.detached(priority: .utility) {
                AppsScanner.scan(extraFolders: folders, spotlightPaths: elsewhere, home: NSHomeDirectory())
            }.value
            entries = found
            byPath = Dictionary(found.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            byBundleID = Dictionary(found.compactMap { entry in entry.bundleID.map { ($0, entry) } },
                                    uniquingKeysWith: { first, _ in first })
            if !isReady { log("apps: \(found.count) apps in \(ms(since: started))") }
            isReady = true
            scanning = false
            if rescanPending {
                rescanPending = false
                scan()
            }
        }
    }

    /// FSEvents on the app folders: an app installed, updated or deleted.
    private func watchFolders() {
        let home = NSHomeDirectory()
        let paths = ([("/Applications"), home + "/Applications"] + extraFolders.map {
            ($0 as NSString).expandingTildeInPath
        }).filter { FileManager.default.fileExists(atPath: $0) }
        watcher = FolderWatcher(paths: paths, latency: 2, queue: .global(qos: .utility)) { [weak self] changed in
            // Only bundles coming or going matter, not files changing inside one (an app's caches, its updater).
            guard changed.contains(where: { AppsScanner.changesTheList($0) }) else { return }
            Task { @MainActor in self?.scheduleRescan() }
        }
    }

    /// Spotlight's application bundles anywhere on this Mac's disks, kept up to date while DigUp runs.
    private func startSpotlight() {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemContentTypeKey, "com.apple.application-bundle")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.notificationBatchingInterval = 2
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.spotlightChanged() }
            })
        }
        self.query = query
        if !query.start() { log("apps: Spotlight's app query didn't start") }
    }

    private func spotlightChanged() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let home = NSHomeDirectory()
        let scanned = AppsScanner.scannedRoots(extraFolders: extraFolders, home: home)
        var paths: [String] = []
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !scanned.contains(where: { path.hasPrefix($0) }),
                  !AppsCatalogRules.isExcludedSpotlightPath(path, home: home),
                  !AppsCatalogRules.isInsideAnotherBundle(path) else { continue }
            paths.append(path)
        }
        paths.sort()
        guard paths != spotlightPaths else { return }
        spotlightPaths = paths
        scheduleRescan(after: .seconds(1))
    }
}

/// Reading app bundles from disk: no main-thread state, so it runs in a detached task.
nonisolated enum AppsScanner {
    /// Deep Search, as Raycast calls it: how many folder levels into an added folder apps are looked for.
    static let extraFolderDepth = 3

    /// The apps in the standard folders, the added ones, and Spotlight's that aren't in those, sorted by name.
    static func scan(extraFolders: [String], spotlightPaths: [String], home: String) -> [AppsEntry] {
        var candidates: [(path: String, source: AppsCatalogRules.Source)] = []
        for folder in AppsCatalogRules.standardFolders(home: home) {
            candidates += findApps(in: folder.path, depth: folder.depth).map { ($0, folder.source) }
        }
        for name in AppsCatalogRules.coreServicesApps.sorted() {
            let path = "/System/Library/CoreServices/" + name
            if FileManager.default.fileExists(atPath: path) { candidates.append((path, .system)) }
        }
        for folder in extraFolders {
            let path = (folder as NSString).expandingTildeInPath
            candidates += findApps(in: path, depth: extraFolderDepth).map { ($0, .installed) }
        }
        candidates += spotlightPaths.map { ($0, .elsewhere) }

        var seen = Set<String>()
        var scanned: [AppsEntry] = []
        var elsewhere: [AppsEntry] = []
        for candidate in candidates where seen.insert(candidate.path).inserted {
            guard let entry = read(candidate.path, source: candidate.source) else { continue }
            if candidate.source == .elsewhere { elsewhere.append(entry) } else { scanned.append(entry) }
        }
        // Spotlight's copies of an app the folders have (a download, an old version on a disk) are left out, and of
        // its own copies only the one in the best place stays. Two copies in the app folders both stay (Xcode and
        // Xcode-beta share a bundle id).
        let known = Set(scanned.compactMap(\.bundleID))
        var best: [String: AppsEntry] = [:]
        var unidentified: [AppsEntry] = []
        for entry in elsewhere {
            guard let id = entry.bundleID else {
                unidentified.append(entry)
                continue
            }
            guard !known.contains(id) else { continue }
            if let current = best[id], AppsCatalogRules.locationRank(current.path, home: home)
                <= AppsCatalogRules.locationRank(entry.path, home: home) { continue }
            best[id] = entry
        }
        return (scanned + Array(best.values) + unidentified).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The folders the scan reads itself (Spotlight's hits in them are already found).
    static func scannedRoots(extraFolders: [String], home: String) -> [String] {
        AppsCatalogRules.standardFolders(home: home).map { $0.path + "/" }
            + extraFolders.map { ($0 as NSString).expandingTildeInPath + "/" }
    }

    /// Whether a path FSEvents reported is an app bundle (or a folder of them) coming or going, rather than a file
    /// inside a bundle changing.
    static func changesTheList(_ path: String) -> Bool {
        guard let range = path.range(of: ".app", options: [.caseInsensitive]) else { return true }
        // "/Applications/Foo.app" itself, not "/Applications/Foo.app/Contents/…".
        let rest = path[range.upperBound...]
        return rest.isEmpty || rest == "/"
    }

    /// App bundles in `folder`, up to `depth` levels down; packages aren't entered. Symbolic links and Finder aliases
    /// to apps count as the apps they point to.
    static func findApps(in folder: String, depth: Int) -> [String] {
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants, .skipsHiddenFiles])
        else { return [] }
        var found: [String] = []
        for case let url as URL in enumerator {
            if enumerator.level > depth {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true || values?.isAliasFile == true {
                // A link to an app (Homebrew's casks, an alias dragged in): the app it points to.
                let target = values?.isSymbolicLink == true
                    ? url.resolvingSymlinksInPath() : (try? URL(resolvingAliasFileAt: url)) ?? url
                if target != url, target.pathExtension.lowercased() == "app",
                   FileManager.default.fileExists(atPath: target.path) {
                    found.append(target.standardizedFileURL.path)
                }
                continue
            }
            if url.pathExtension.lowercased() == "app" {
                found.append(url.path)
                enumerator.skipDescendants()
            }
        }
        return found
    }

    /// The app at `path`, or nil when it isn't one to list (a background helper, an agent of the system's).
    static func read(_ path: String, source: AppsCatalogRules.Source) -> AppsEntry? {
        // A Mac app's Info.plist, or an iPhone or iPad app's inside its wrapper.
        let plist = ["/Contents/Info.plist", "/WrappedBundle/Info.plist"].lazy
            .compactMap { NSDictionary(contentsOfFile: path + $0) as? [String: Any] }.first
        guard let plist else {
            // Not an app bundle Spotlight would vouch for (a simulator build, a broken copy).
            return source == .elsewhere ? nil : AppsEntry(
                path: path, name: displayName(path), keywords: [], bundleID: nil, version: nil)
        }
        // A bundle named .app that isn't one (some installers ship plug-ins that way).
        if let type = plist["CFBundlePackageType"] as? String, !["APPL", "????", ""].contains(type) { return nil }
        guard AppsCatalogRules.shouldList(isUIElement: AppsCatalogRules.isFlagOn(plist["LSUIElement"]),
                                          isBackgroundOnly: AppsCatalogRules.isFlagOn(plist["LSBackgroundOnly"]),
                                          source: source) else { return nil }
        let name = displayName(path)
        let bundleID = plist["CFBundleIdentifier"] as? String
        let keywords = AppsCatalogRules.keywords(
            name: name, bundleName: plist["CFBundleName"] as? String,
            bundleDisplayName: plist["CFBundleDisplayName"] as? String,
            executable: plist["CFBundleExecutable"] as? String,
            fileName: (path as NSString).lastPathComponent, bundleID: bundleID,
            alternateNames: alternateNames(path))
        let version = AppsCatalogRules.versionText(short: plist["CFBundleShortVersionString"] as? String,
                                                   build: plist["CFBundleVersion"] as? String)
        return AppsEntry(path: path, name: name, keywords: keywords, bundleID: bundleID, version: version)
    }

    /// The name Finder shows, localized, without ".app".
    static func displayName(_ path: String) -> String {
        var name = FileManager.default.displayName(atPath: path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name
    }

    /// Spotlight's other names for an app ("iCal" for Calendar, "Preferences" for System Settings).
    static func alternateNames(_ path: String) -> [String] {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              // Not in the SDK's headers, but Spotlight keeps it for apps.
              let names = MDItemCopyAttribute(item, "kMDItemAlternateNames" as CFString) as? [String]
        else { return [] }
        return names
    }
}

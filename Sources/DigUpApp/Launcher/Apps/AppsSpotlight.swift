import AppKit
import CoreServices
import DigUpKit

/// A file or folder found by name, with what its row and preview show. Read on any thread.
nonisolated struct AppsFileHit: Sendable {
    let url: URL
    let name: String
    let kind: String?
    let size: Int64?
    let modified: Date?
    let lastUsed: Date?
    let isFolder: Bool
    /// An app, a library or another package Finder shows as one file.
    let isPackage: Bool

    var path: String { url.path }

    /// A Spotlight result, nil when it has no path.
    init?(_ item: NSMetadataItem) {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        url = URL(fileURLWithPath: path)
        name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? url.lastPathComponent
        kind = item.value(forAttribute: NSMetadataItemKindKey) as? String
        size = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value
        modified = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
        lastUsed = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
        let types = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
        // An app or a library is a directory too, but Finder shows it as one file.
        isPackage = types.contains("com.apple.package")
        isFolder = !isPackage && (types.contains("public.folder") || types.contains("public.directory"))
    }

    /// What `init(path:)` reads, to prefetch when listing a folder.
    static let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey,
                                            .isDirectoryKey, .isPackageKey]

    /// A file read from disk (a favorite, a typed path), nil when it isn't there.
    init?(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: Self.keys) else { return nil }
        self.url = url
        name = url.lastPathComponent
        kind = values.localizedTypeDescription
        size = values.isDirectory == true ? nil : values.fileSize.map(Int64.init)
        modified = values.contentModificationDate
        lastUsed = MDItemCreate(kCFAllocatorDefault, path as CFString)
            .flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        isPackage = values.isPackage == true
        isFolder = values.isDirectory == true && !isPackage
    }
}

/// One Spotlight query, run until it has gathered its results, a timeout passes, or the task is cancelled.
/// NSMetadataQuery runs on the main run loop, so this stays on the main actor and never blocks it.
enum AppsSpotlight {
    /// Your home folder and /Applications, as Raycast's File Search indexes by default.
    static var scopes: [Any] { [NSMetadataQueryUserHomeScope, URL(fileURLWithPath: "/Applications")] }

    /// The first `limit` results of `queryString` (MDQuery syntax), most recently used first; whatever was found by
    /// `timeout` if Spotlight is slow, nothing when cancelled.
    static func search(_ queryString: String, limit: Int, timeout: Duration = .seconds(2)) async -> [AppsFileHit] {
        guard !Task.isCancelled, let predicate = NSPredicate(fromMetadataQueryString: queryString) else { return [] }
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scopes
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        query.notificationBatchingInterval = 0.05
        let run = AppsSpotlightRun(query: query, limit: limit)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                run.begin(continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor in run.finish(cancelled: true) }
        }
    }
}

/// The state of one running query: its observer, its timeout, and the caller waiting for it.
private final class AppsSpotlightRun {
    private let query: NSMetadataQuery
    private let limit: Int
    private var continuation: CheckedContinuation<[AppsFileHit], Never>?
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var done = false

    init(query: NSMetadataQuery, limit: Int) {
        self.query = query
        self.limit = limit
    }

    func begin(_ continuation: CheckedContinuation<[AppsFileHit], Never>, timeout: Duration) {
        guard !done else {
            continuation.resume(returning: [])
            return
        }
        self.continuation = continuation
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                          object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(cancelled: false) }
        }
        guard query.start() else {
            log("apps: a Spotlight file query didn't start")
            finish(cancelled: true)
            return
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(cancelled: false)
        }
    }

    /// Stops the query and hands what it found (nothing when cancelled) to the caller, once.
    func finish(cancelled: Bool) {
        guard !done else { return }
        done = true
        timeoutTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        query.stop()
        var hits: [AppsFileHit] = []
        if !cancelled {
            query.disableUpdates()
            let count = min(query.resultCount, limit)
            hits.reserveCapacity(count)
            for index in 0..<count {
                if let item = query.result(at: index) as? NSMetadataItem, let hit = AppsFileHit(item) {
                    hits.append(hit)
                }
            }
        }
        continuation?.resume(returning: hits)
        continuation = nil
    }
}

/// Files by name: Spotlight's hits for what's typed, without the ones that aren't your files, ranked by how well
/// the name matches and how lately the file was used.
enum AppsFileFinder {
    /// How many of Spotlight's hits are looked at: they come most recently used first, so a good name match that's
    /// old still makes it in.
    static let scanned = 300

    static func find(_ text: String, limit: Int, includeApps: Bool) async -> [(hit: AppsFileHit, score: Double)] {
        guard let queryString = AppsFileSearchRules.spotlightQuery(for: text) else { return [] }
        let hits = await AppsSpotlight.search(queryString, limit: scanned)
        guard !Task.isCancelled else { return [] }
        let home = NSHomeDirectory()
        let now = Date()
        var ranked: [(hit: AppsFileHit, score: Double)] = []
        var seen = Set<String>()
        for hit in hits where seen.insert(hit.path).inserted {
            guard !AppsFileSearchRules.isExcluded(hit.path, home: home) else { continue }
            if !includeApps, hit.url.pathExtension.lowercased() == "app" { continue }
            // Spotlight matched every word; the fuzzy score says how well (a name starting with them is better).
            let match = FuzzyMatch.best(text, name: hit.name, keywords: [(hit.name as NSString).deletingPathExtension])
                ?? 0.3
            ranked.append((hit, AppsFileSearchRules.score(match: match, lastUsed: hit.lastUsed,
                                                           modified: hit.modified, now: now)))
        }
        ranked.sort { $0.score > $1.score }
        return Array(ranked.prefix(limit))
    }

    /// Files opened in the last `days` days, most recent first (Search Files with nothing typed). Apps are left out:
    /// they're opened all the time and are in root search already.
    static func recent(days: Int, limit: Int) async -> [AppsFileHit] {
        let hits = await AppsSpotlight.search(AppsFileSearchRules.recentlyUsed(days: days), limit: limit * 3)
        let home = NSHomeDirectory()
        return Array(hits.filter { hit in
            !hit.isFolder && hit.url.pathExtension.lowercased() != "app"
                && !AppsFileSearchRules.isExcluded(hit.path, home: home)
        }.prefix(limit))
    }
}

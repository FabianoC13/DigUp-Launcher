import AppKit
import DigUpKit
import Observation

/// Clipboard History's entries and settings, in Launcher.directory/Clipboard: history.json (the index), settings.json,
/// images/ (each image's PNG and its thumbnail), rich/ (the RTF and HTML kept to paste a text back formatted) and
/// text/ (the whole of texts too long for the index).
@Observable
final class ClipboardStore {
    static let shared = ClipboardStore()

    /// An app whose copies aren't recorded.
    struct IgnoredApp: Codable, Hashable, Identifiable {
        var bundleID: String
        var name: String
        var id: String { bundleID }
    }

    struct Settings: Codable, Equatable {
        var retention = ClipboardRetention.standard
        var paused = false
        var ignoredApps = ClipboardHistoryRules.defaultIgnoredApps.map { IgnoredApp(bundleID: $0.bundleID, name: $0.name) }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Settings()
            retention = (try? container.decodeIfPresent(ClipboardRetention.self, forKey: .retention)) ?? defaults.retention
            paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? defaults.paused
            ignoredApps = try container.decodeIfPresent([IgnoredApp].self, forKey: .ignoredApps) ?? defaults.ignoredApps
        }
    }

    private(set) var entries: [ClipboardEntry] = []
    private(set) var loaded = false
    var settings = Settings() {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            if settings.retention != oldValue.retention { prune() }
        }
    }

    @ObservationIgnored private let disk = ClipboardDisk()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var searchTexts: [String: String] = [:]
    @ObservationIgnored private var thumbnails: [String: NSImage] = [:]
    /// Pasteboard change counts DigUp made itself, with the entry each one put back (nil: not an entry, don't record).
    @ObservationIgnored private var ownWrites: [Int: String?] = [:]
    /// Called after the entries changed (a copy, a delete): an open Clipboard History refreshes.
    @ObservationIgnored var onChange: [() -> Void] = []

    // MARK: Places

    static var directory: URL { Launcher.directory.appendingPathComponent("Clipboard", isDirectory: true) }
    private var indexURL: URL { Self.directory.appendingPathComponent("history.json") }
    private var settingsURL: URL { Self.directory.appendingPathComponent("settings.json") }
    var imagesDirectory: URL { Self.directory.appendingPathComponent("images", isDirectory: true) }
    private var richDirectory: URL { Self.directory.appendingPathComponent("rich", isDirectory: true) }
    private var textDirectory: URL { Self.directory.appendingPathComponent("text", isDirectory: true) }

    func imageURL(_ id: String) -> URL { imagesDirectory.appendingPathComponent("\(id).png") }
    func thumbnailURL(_ id: String) -> URL { imagesDirectory.appendingPathComponent("\(id)-thumb.png") }
    func textURL(_ id: String) -> URL { textDirectory.appendingPathComponent("\(id).txt") }
    func richURL(_ id: String, type: String) -> URL {
        let ext = switch type {
        case NSPasteboard.PasteboardType.rtf.rawValue: "rtf"
        case NSPasteboard.PasteboardType.html.rawValue: "html"
        default: String(type.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        }
        return richDirectory.appendingPathComponent("\(id).\(ext)")
    }

    /// Every file an entry has beside the index.
    private func files(of entry: ClipboardEntry) -> [URL] {
        [imageURL(entry.id), thumbnailURL(entry.id), textURL(entry.id)] + entry.richTypes.map { richURL(entry.id, type: $0) }
    }

    // MARK: Loading and saving

    /// Reads the settings and the index (off the main thread: it can be megabytes), then drops what expired.
    func load() async {
        guard !loaded else { return }
        if let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        }
        let url = indexURL
        let saved = await Task.detached(priority: .userInitiated) { () -> [ClipboardEntry]? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode([ClipboardEntry].self, from: data)
        }.value
        // Anything recorded while the index loaded goes on top of it.
        var merged = saved ?? []
        for entry in entries.reversed() { merged = ClipboardHistoryRules.record(entry, into: merged).entries }
        entries = merged
        loaded = true
        log("clipboard: \(entries.count) entries in the history")
        prune()
    }

    private func saveSettings() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
        } catch {
            log("clipboard: couldn't save the settings: \(error.localizedDescription)")
        }
    }

    /// Writes the index a second after the last change, off the main thread.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            await disk.writeIndex(entries, to: indexURL)
        }
    }

    /// Writes the index now (the app is quitting).
    func saveNow() {
        saveTask?.cancel()
        guard loaded else { return }
        ClipboardDisk.encodeIndex(entries, to: indexURL)
    }

    private func changed() {
        scheduleSave()
        for observer in onChange { observer() }
    }

    // MARK: Changing the history

    var ignoredBundleIDs: Set<String> { Set(settings.ignoredApps.map(\.bundleID)) }
    var knownFingerprints: Set<String> { Set(entries.map(\.fingerprint)) }

    func entry(_ id: String) -> ClipboardEntry? { entries.first { $0.id == id } }

    /// A copy: new on top, or the same content as before moved there. `files` are written first when it's new.
    @discardableResult
    func record(_ entry: ClipboardEntry, files: [(URL, Data)] = []) -> String {
        let result = ClipboardHistoryRules.record(entry, into: entries)
        if result.isNew, !files.isEmpty {
            let disk = disk
            Task { await disk.write(files) }
        }
        entries = result.entries
        searchTexts[result.id] = nil
        prune()
        changed()
        return result.id
    }

    /// Text read from an image arrived.
    func setRecognizedText(_ text: String, for id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].recognizedText = text
        searchTexts[id] = nil
        changed()
    }

    /// Used again from the history: on top, as if just copied.
    func touch(_ id: String) {
        entries = ClipboardHistoryRules.touch(id, in: entries, at: Date())
        changed()
    }

    func togglePin(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned.toggle()
        changed()
    }

    func rename(_ id: String, to title: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        searchTexts[id] = nil
        changed()
    }

    func delete(_ id: String) {
        guard let entry = entry(id) else { return }
        entries.removeAll { $0.id == id }
        removeFiles(of: [entry])
        changed()
    }

    /// Delete All: everything but the pinned entries.
    func deleteAllUnpinned() {
        let (kept, removed) = ClipboardHistoryRules.clearing(entries)
        guard !removed.isEmpty else { return }
        entries = kept
        removeFiles(of: removed)
        changed()
        log("clipboard: deleted \(removed.count) entries")
    }

    /// Drops what's older than the retention period and the oldest past 1,000 entries.
    func prune() {
        guard loaded else { return }
        let (kept, removed) = ClipboardHistoryRules.pruned(entries, retention: settings.retention, now: Date())
        guard !removed.isEmpty else { return }
        entries = kept
        removeFiles(of: removed)
        changed()
    }

    private func removeFiles(of removed: [ClipboardEntry]) {
        for entry in removed {
            searchTexts[entry.id] = nil
            thumbnails[entry.id] = nil
        }
        let urls = removed.flatMap(files(of:))
        let disk = disk
        Task { await disk.remove(urls) }
    }

    // MARK: Reading entries

    /// What a search looks through, worked out once per entry.
    func searchText(of entry: ClipboardEntry) -> String {
        if let cached = searchTexts[entry.id] { return cached }
        let text = ClipboardHistoryRules.searchText(of: entry)
        searchTexts[entry.id] = text
        return text
    }

    /// The whole text, also when only its start is in the index.
    func fullText(of entry: ClipboardEntry) -> String {
        guard entry.textInFile, let whole = try? String(contentsOf: textURL(entry.id), encoding: .utf8) else {
            return entry.text
        }
        return whole
    }

    /// A small picture of an image entry, read from disk only when it's drawn.
    func thumbnail(of entry: ClipboardEntry) -> NSImage? {
        if let cached = thumbnails[entry.id] { return cached }
        let url = FileManager.default.fileExists(atPath: thumbnailURL(entry.id).path) ? thumbnailURL(entry.id)
            : imageURL(entry.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let image = NSImage(byReferencing: url)
        thumbnails[entry.id] = image
        return image
    }

    // MARK: The pasteboard

    /// Whether DigUp made this pasteboard change itself; the entry it put back, if it was one. Forgets it.
    func takeOwnWrite(_ changeCount: Int) -> String?? {
        guard let own = ownWrites.removeValue(forKey: changeCount) else { return nil }
        return .some(own)
    }

    /// The pasteboard as it is now was put there by DigUp and isn't a copy to record (a restored clipboard).
    func ignoreCurrentPasteboard() {
        ownWrites[NSPasteboard.general.changeCount] = .some(nil)
    }

    /// Puts an entry back on the clipboard with all it had (RTF, HTML, PNG and TIFF, file URLs), or as plain text.
    /// False when its data is gone.
    @discardableResult
    func write(_ entry: ClipboardEntry, plainText: Bool = false) -> Bool {
        let pasteboard = NSPasteboard.general
        switch entry.kind {
        case .image:
            guard let png = try? Data(contentsOf: imageURL(entry.id)) else { return false }
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            // Older apps only read TIFF; skip it for huge images (it's uncompressed).
            if (entry.imageWidth ?? 0) * (entry.imageHeight ?? 0) <= 12_000_000,
               let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
        case .files:
            let urls = entry.files.map { URL(fileURLWithPath: $0) }
            pasteboard.clearContents()
            if plainText {
                pasteboard.setString(entry.files.joined(separator: "\n"), forType: .string)
            } else {
                pasteboard.writeObjects(urls as [NSURL])
            }
        default:
            let item = NSPasteboardItem()
            item.setString(fullText(of: entry), forType: .string)
            if !plainText {
                for type in entry.richTypes {
                    if let data = try? Data(contentsOf: richURL(entry.id, type: type)) {
                        item.setData(data, forType: NSPasteboard.PasteboardType(type))
                    }
                }
                if entry.kind == .link, let url = ClipboardClassifier.link(in: entry.text) {
                    item.setString(url.absoluteString, forType: .URL)
                }
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
        }
        ownWrites[pasteboard.changeCount] = .some(entry.id)
        return true
    }
}

/// The history's files, written and deleted one at a time off the main thread.
actor ClipboardDisk {
    func writeIndex(_ entries: [ClipboardEntry], to url: URL) {
        Self.encodeIndex(entries, to: url)
    }

    nonisolated static func encodeIndex(_ entries: [ClipboardEntry], to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log("clipboard: couldn't save the history: \(error.localizedDescription)")
        }
    }

    func write(_ files: [(URL, Data)]) {
        for (url, data) in files {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                log("clipboard: couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    func remove(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

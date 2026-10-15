import AppKit
import DigUpKit
import Observation
import SwiftUI

/// The quicklinks and the feature's settings, read once at launch and saved as JSON in Launcher/Quicklinks/: what the
/// providers, the windows and Settings share. Observable, so Settings follows changes made from the panel.
@Observable
final class QuicklinksStore {
    private(set) var links: [QuicklinkRecord] = []
    private(set) var settings = QuicklinksSettings()
    /// Bumped when favorites, aliases or hotkeys change (the launcher's usage isn't observable), so Settings re-reads
    /// them.
    private(set) var personalizationRevision = 0
    /// Item ids whose hotkey couldn't be registered (another app has the combination).
    var failedHotkeys: Set<String> = []
    /// What the Hyper Key is doing, for Settings.
    var hyperKeyStatus = QuicklinksHyperKeyStatus.off

    @ObservationIgnored let favicons: QuicklinksFavicons
    @ObservationIgnored private var templates: [String: QuicklinkTemplate] = [:]
    @ObservationIgnored private var icons: [String: LauncherIcon] = [:]

    static var directory: URL { Launcher.directory.appendingPathComponent("Quicklinks", isDirectory: true) }
    private static var linksFile: URL { directory.appendingPathComponent("quicklinks.json") }
    private static var settingsFile: URL { directory.appendingPathComponent("settings.json") }

    init() {
        favicons = QuicklinksFavicons(folder: Self.directory.appendingPathComponent("icons", isDirectory: true))
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        loadLinks()
        if let data = try? Data(contentsOf: Self.settingsFile),
           let saved = try? JSONDecoder().decode(QuicklinksSettings.self, from: data) {
            settings = saved
        }
    }

    /// The file, or the default quicklinks on a first run. A file that can't be read is set aside (not overwritten),
    /// so nothing is lost to a bad edit by hand.
    private func loadLinks() {
        let file = Self.linksFile
        guard let data = try? Data(contentsOf: file) else {
            links = QuicklinkRecord.defaults()
            saveLinks()
            log("quicklinks: first run, \(links.count) defaults")
            return
        }
        do {
            links = Self.unique(try JSONDecoder().decode([QuicklinkRecord].self, from: data))
        } catch {
            let aside = file.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            log("quicklinks: \(file.lastPathComponent) can't be read (\(error)); set aside as \(aside.lastPathComponent)")
            links = []
        }
    }

    /// Ids are item keys ("ql:<id>"), so they must be unique and must not look like a command's ("@create").
    private static func unique(_ records: [QuicklinkRecord]) -> [QuicklinkRecord] {
        var seen = Set<String>()
        return records.map { record in
            var record = record
            if record.id.isEmpty || record.id.hasPrefix("@") || record.id.contains(":") || seen.contains(record.id) {
                record.id = UUID().uuidString
            }
            seen.insert(record.id)
            return record
        }
    }

    // MARK: Quicklinks

    func record(id: String) -> QuicklinkRecord? {
        links.first { $0.id == id }
    }

    /// The quicklink a link or a deeplink names: its id, its name or its keyword (case and accents aside).
    func record(named name: String) -> QuicklinkRecord? {
        let key = FuzzyMatch.normalize(name)
        return links.first { $0.id == name }
            ?? links.first { FuzzyMatch.normalize($0.name) == key }
            ?? links.first { $0.keyword.map(FuzzyMatch.normalize) == key }
    }

    func template(for record: QuicklinkRecord) -> QuicklinkTemplate {
        if let template = templates[record.link] { return template }
        let template = QuicklinkTemplate(record.link)
        templates[record.link] = template
        return template
    }

    /// Adds a new quicklink or replaces the one with its id.
    func save(_ record: QuicklinkRecord) {
        if let index = links.firstIndex(where: { $0.id == record.id }) {
            links[index] = record
        } else {
            links.append(record)
        }
        icons[record.id] = nil
        saveLinks()
    }

    /// A copy named "… Copy", without the keyword (keywords are one quicklink's each).
    @discardableResult
    func duplicate(_ record: QuicklinkRecord) -> QuicklinkRecord {
        let copy = QuicklinkRecord(name: record.name + " Copy", link: record.link, openWith: record.openWith)
        if let index = links.firstIndex(where: { $0.id == record.id }) {
            links.insert(copy, at: index + 1)
        } else {
            links.append(copy)
        }
        saveLinks()
        return copy
    }

    func delete(_ record: QuicklinkRecord) {
        links.removeAll { $0.id == record.id }
        icons[record.id] = nil
        saveLinks()
    }

    /// Several at once (an import).
    func replaceAll(_ records: [QuicklinkRecord]) {
        links = Self.unique(records)
        icons = [:]
        saveLinks()
    }

    private func saveLinks() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(links) else { return }
        Self.write(data, to: Self.linksFile)
    }

    // MARK: Settings

    /// Changes and saves the settings; `now` writes the file before returning (at quit, when a background write
    /// wouldn't get to run).
    func updateSettings(now: Bool = false, _ change: (inout QuicklinksSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(copy) else { return }
        if now {
            try? data.write(to: Self.settingsFile, options: .atomic)
        } else {
            Self.write(data, to: Self.settingsFile)
        }
    }

    /// The fallback commands in their order, built-ins and single-argument quicklinks, each on or off.
    var fallbackEntries: [QuicklinksFallbackEntry] {
        QuicklinksFallbacks.normalized(settings.fallbacks, quicklinks: fallbackQuicklinks.map(\.id))
    }

    /// Quicklinks that take exactly one argument, so they can take what was typed.
    var fallbackQuicklinks: [QuicklinkRecord] {
        links.filter { template(for: $0).arguments.count == 1 }
    }

    func setFallback(_ id: String, enabled: Bool) {
        var entries = fallbackEntries
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].enabled = enabled
        updateSettings { $0.fallbacks = entries }
    }

    func moveFallback(at index: Int, by offset: Int) {
        var entries = fallbackEntries
        QuicklinksFallbacks.move(&entries, at: index, by: offset)
        updateSettings { $0.fallbacks = entries }
    }

    func personalizationChanged() {
        personalizationRevision += 1
    }

    // MARK: Icons

    /// The app it opens in, the file it points at, the app of its URL scheme, or the site's favicon (fetched once, in
    /// the background; a globe until then).
    func icon(for record: QuicklinkRecord) -> LauncherIcon {
        if let icon = icons[record.id] { return icon }
        let icon: LauncherIcon
        var final = true
        if let bundle = record.openWith, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            icon = .file(app)
        } else if QuicklinkTemplate.isPath(record.link) {
            let path = (record.link.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            icon = !path.contains("{") && FileManager.default.fileExists(atPath: path)
                ? .file(URL(fileURLWithPath: path)) : .symbol("folder", .blue)
        } else if let host = QuicklinkTemplate.webHost(record.link) {
            if let image = favicons.image(for: host) {
                icon = .image(image)
            } else {
                icon = .symbol("globe", .blue)
                final = false
            }
        } else if let url = QuicklinkTemplate.destination(sample(record), home: NSHomeDirectory()),
                  let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            icon = .file(app)
        } else {
            icon = .symbol("link", .blue)
        }
        if final { icons[record.id] = icon }
        return icon
    }

    /// The link filled with stand-ins, to see what kind of thing it opens.
    func sample(_ record: QuicklinkRecord) -> String {
        let template = template(for: record)
        var arguments: [String: String] = [:]
        for argument in template.arguments { arguments[argument.key] = argument.defaultValue ?? "x" }
        return template.filled(.init(arguments: arguments, clipboard: "x"))
    }

    // MARK: Opening

    /// The link with these arguments (and the clipboard, when it asks for it).
    func filled(_ record: QuicklinkRecord, arguments: [String: String], readClipboard: Bool = true) -> String {
        let template = template(for: record)
        let clipboard = readClipboard && template.usesClipboard
            ? NSPasteboard.general.string(forType: .string) : nil
        return template.filled(.init(arguments: arguments, clipboard: clipboard ?? ""))
    }

    /// Opens a quicklink with what was typed for it, in its app when it names one. Nil when it opened, else why not.
    @discardableResult
    func open(_ record: QuicklinkRecord, arguments: [String: String]) async -> String? {
        let filled = filled(record, arguments: arguments)
        guard let url = QuicklinkTemplate.destination(filled, home: NSHomeDirectory()) else {
            log("quicklinks: “\(record.name)” isn't a link that can be opened")
            return "“\(record.name)” isn't a link, a path or an app URL"
        }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            log("quicklinks: “\(record.name)” points at a missing file")
            return "Nothing is at \(tildePath(url.path))"
        }
        return await Self.open(url, bundleID: record.openWith)
    }

    /// Opens `url` in the app with this bundle id (or its default app). Nil when it opened, else why not.
    static func open(_ url: URL, bundleID: String?) async -> String? {
        if let bundleID {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                log("quicklinks: no app \(bundleID) to open with")
                return "The app it opens in (\(bundleID)) isn't installed"
            }
            return await open(url, withApplicationAt: app)
        }
        guard NSWorkspace.shared.open(url) else {
            log("quicklinks: no app opens \(url.isFileURL ? "this file" : url.scheme ?? "this link")")
            return "No app opens this link"
        }
        return nil
    }

    static func open(_ url: URL, withApplicationAt app: URL) async -> String? {
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
            return nil
        } catch {
            log("quicklinks: \(app.lastPathComponent) couldn't open it: \(error.localizedDescription)")
            return "\(app.deletingPathExtension().lastPathComponent) couldn't open it"
        }
    }

    // MARK: Files

    /// Atomically, off the main thread.
    static func write(_ data: Data, to file: URL) {
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                log("quicklinks: can't save \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}

/// The Hyper Key's state, as Settings shows it.
enum QuicklinksHyperKeyStatus: Equatable {
    case off
    case on
    /// Turned on, but DigUp isn't allowed in Accessibility, so Caps Lock is left alone.
    case needsAccessibility
    case failed(String)
}

/// Sites' icons for web quicklinks, from Google's favicon service, fetched once per site and kept as PNGs in
/// Launcher/Quicklinks/icons/.
final class QuicklinksFavicons {
    private let folder: URL
    private var images: [String: NSImage] = [:]
    /// Sites asked for (or on disk) this launch: each is fetched at most once.
    private var tried: Set<String> = []
    private var loaded = false

    init(folder: URL) {
        self.folder = folder
    }

    /// Reads the icons already fetched, in the background.
    func preload() {
        let folder = self.folder
        Task {
            let found: [(String, Data)] = await Task.detached(priority: .utility) {
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
                    ?? []
                return files.filter { $0.pathExtension == "png" }.compactMap { file in
                    (try? Data(contentsOf: file)).map { (file.deletingPathExtension().lastPathComponent, $0) }
                }
            }.value
            for (host, data) in found {
                tried.insert(host)
                if let image = NSImage(data: data) { images[host] = image }
            }
            loaded = true
        }
    }

    /// The site's icon if it's here; otherwise nil, and it's fetched for next time.
    func image(for host: String) -> NSImage? {
        let host = Self.fileName(host)
        if let image = images[host] { return image }
        if loaded, !host.isEmpty, tried.insert(host).inserted { fetch(host) }
        return nil
    }

    private func fetch(_ host: String) {
        guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64") else { return }
        let file = folder.appendingPathComponent(host + ".png")
        Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data),
                  image.size.width >= 16 else {
                log("quicklinks: no favicon for \(host)")
                return
            }
            images[host] = image
            QuicklinksStore.write(data, to: file)
        }
    }

    /// A host as a file name: letters, digits, dots and dashes.
    private static func fileName(_ host: String) -> String {
        String(host.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        }.map(Character.init))
    }
}

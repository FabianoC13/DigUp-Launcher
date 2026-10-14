import AppKit
import DigUpKit
import Observation
import SwiftUI

/// A script with Raycast's `@raycast.*` metadata, found in a scripts folder.
struct ScriptCommand: Sendable, Identifiable {
    let url: URL
    let metadata: ScriptCommandMetadata
    /// The `#!` line, for scripts that aren't executable.
    let firstLine: String?
    let isExecutable: Bool

    /// "script:<path>": stable while the file stays where it is (favorites, aliases and hotkeys keep it).
    var id: String { ScriptsLibrary.itemPrefix + url.path }
    var title: String { metadata.title }
}

/// The script commands in DigUp's scripts folder (`Launcher.directory/Scripts`) and the one you add in Settings:
/// scanned off the main thread, and again when a folder changes.
@Observable
final class ScriptsLibrary {
    static let shared = ScriptsLibrary()
    static let itemPrefix = "script:"

    /// Settings, kept beside the scripts (hidden, so it's never taken for one).
    struct Settings: Codable, Equatable {
        var extraFolder: String?
    }

    /// The last output of an inline script, shown in its row.
    struct InlineOutput {
        let text: String
        let at: Date
    }

    private(set) var scripts: [ScriptCommand] = []
    /// Files with `@raycast.title` that have something wrong with them: path → what.
    private(set) var problems: [(file: String, message: String)] = []
    private(set) var settings = Settings()
    private(set) var lastScan = Date.distantPast
    private(set) var scanning = false
    var inlineOutputs: [String: InlineOutput] = [:]
    /// Icons from a file or a URL, by the `@raycast.icon` text.
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var iconsLoading: Set<String> = []
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    /// The scripts folder DigUp makes.
    static var folder: URL { ProductivityFiles.folder("Scripts") }
    private static var settingsFile: URL { folder.appendingPathComponent(".digup-settings.json") }
    /// A script's header is at its top; more isn't read.
    nonisolated static let headerBytes = 16 * 1024
    /// Files bigger than this aren't scripts anyone wrote by hand (a binary, a data file).
    nonisolated static let maxScriptSize = 2 * 1024 * 1024

    var folders: [URL] {
        var folders = [Self.folder]
        if let extra = settings.extraFolder, !extra.isEmpty {
            let url = URL(fileURLWithPath: (extra as NSString).expandingTildeInPath, isDirectory: true)
            if url.standardizedFileURL != Self.folder.standardizedFileURL { folders.append(url) }
        }
        return folders
    }

    func start() {
        guard !started else { return }
        started = true
        settings = ProductivityFiles.load(Settings.self, from: Self.settingsFile) ?? Settings()
        rescan()
        watchFolders()
    }

    /// Rescans when the last scan is a while ago: edits inside a file don't always touch its folder.
    func rescanIfStale(after seconds: TimeInterval = 15) {
        if Date().timeIntervalSince(lastScan) > seconds { rescan() }
    }

    /// Reads every folder again, off the main thread.
    func rescan() {
        guard !scanning else { return }
        scanning = true
        let folders = self.folders
        Task {
            let found = await Task.detached(priority: .utility) { Self.scan(folders) }.value
            scripts = found.scripts
            problems = found.problems
            lastScan = Date()
            scanning = false
            log("scripts: \(found.scripts.count) script commands in \(folders.map { tildePath($0.path) })"
                + (found.problems.isEmpty ? "" : ", \(found.problems.count) with problems"))
        }
    }

    /// A rescan shortly after a folder changed (an editor's save is several changes).
    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            rescan()
        }
    }

    func setExtraFolder(_ url: URL?) {
        settings.extraFolder = url.map { tildePath($0.path) }
        ProductivityFiles.save(settings, to: Self.settingsFile)
        watchFolders()
        rescan()
    }

    func script(id: String) -> ScriptCommand? {
        scripts.first { $0.id == id }
    }

    // MARK: Scanning

    nonisolated static func scan(_ folders: [URL]) -> (scripts: [ScriptCommand], problems: [(file: String, message: String)]) {
        var scripts: [ScriptCommand] = []
        var problems: [(file: String, message: String)] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let manager = FileManager.default
        func files(in folder: URL) -> [URL] {
            (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                              options: [.skipsHiddenFiles])) ?? []
        }
        for folder in folders {
            // The folder and one level of subfolders (scripts grouped by package).
            var candidates: [URL] = []
            for url in files(in: folder) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    candidates += files(in: url).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
                } else if values?.isRegularFile == true {
                    candidates.append(url)
                }
            }
            for url in candidates.sorted(by: { $0.path < $1.path }) {
                guard seen.insert(url.standardizedFileURL.path).inserted,
                      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxScriptSize,
                      let handle = try? FileHandle(forReadingFrom: url) else { continue }
                let head = (try? handle.read(upToCount: headerBytes)) ?? nil
                try? handle.close()
                guard let head, !head.contains(0) else { continue }   // a NUL byte: a binary, not a script
                let text = String(decoding: head, as: UTF8.self)
                guard let metadata = ScriptCommandMetadata.parse(text) else { continue }
                let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
                    .map(String.init)
                let executable = manager.isExecutableFile(atPath: url.path)
                let script = ScriptCommand(url: url, metadata: metadata, firstLine: firstLine, isExecutable: executable)
                var issues = metadata.warnings
                if !executable, ScriptCommandLine.interpreter(firstLine: firstLine, pathExtension: url.pathExtension) == nil {
                    issues.append("Not executable and no #! line: run chmod +x on it")
                }
                if !issues.isEmpty { problems.append((url.lastPathComponent, issues.joined(separator: "; "))) }
                scripts.append(script)
            }
        }
        return (scripts, problems)
    }

    // MARK: Watching

    /// A file system source per folder: files added, removed, renamed or saved over (editors save by replacing).
    private func watchFolders() {
        for watcher in watchers { watcher.cancel() }
        watchers = []
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else {
                log("scripts: can't watch \(tildePath(folder.path))")
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .rename, .delete, .link],
                                                                   queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { ScriptsLibrary.shared.scheduleRescan() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    // MARK: Icons

    /// The script's `@raycast.icon`: an emoji, an image file (beside the script, or a path), or an image URL (fetched
    /// once, then kept). The dark variant in dark mode.
    func icon(for script: ScriptCommand) -> LauncherIcon {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let spec = ((dark ? script.metadata.iconDark : nil) ?? script.metadata.icon)?
            .trimmingCharacters(in: .whitespaces), !spec.isEmpty else {
            return .symbol("terminal")
        }
        if Self.isGlyph(spec) { return .glyph(spec) }
        if let image = icons[spec] { return .image(image) }
        if spec.hasPrefix("http://") || spec.hasPrefix("https://") {
            loadRemoteIcon(spec)
        } else {
            let expanded = (spec as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : script.url.deletingLastPathComponent().appendingPathComponent(expanded)
            if let image = NSImage(contentsOf: url) {
                icons[spec] = image
                return .image(image)
            }
        }
        return .symbol("terminal")
    }

    /// An emoji or a short symbol, drawn as text: no slash, no file extension.
    static func isGlyph(_ text: String) -> Bool {
        text.count <= 2 && !text.contains("/") && !text.contains(".")
    }

    private func loadRemoteIcon(_ spec: String) {
        guard !iconsLoading.contains(spec), let url = URL(string: spec) else { return }
        iconsLoading.insert(spec)
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = NSImage(data: data) { icons[spec] = image }
            } catch {
                log("scripts: icon \(url.host ?? "?") didn't load (\(error.localizedDescription))")
            }
        }
    }

    // MARK: New scripts

    /// Writes a Bash script command with its metadata filled in, executable, and opens it to edit.
    func create(title: String) -> URL? {
        let folder = Self.folder
        let name = ScriptCommandLine.fileName(forTitle: title)
        var url = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent((name as NSString).deletingPathExtension + "-\(number).sh")
            number += 1
        }
        do {
            try ScriptCommandLine.template(title: title).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            log("scripts: couldn't create \(url.lastPathComponent) (\(error.localizedDescription))")
            return nil
        }
        rescan()
        return url
    }
}

/// Settings → Launcher → Script Commands.
struct ScriptsSettingsView: View {
    @Bindable var library: ScriptsLibrary

    var body: some View {
        LabeledContent("Scripts folder") {
            HStack {
                Text(tildePath(ScriptsLibrary.folder.path))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Open") { NSWorkspace.shared.open(ScriptsLibrary.folder) }
            }
        }
        LabeledContent("Another folder") {
            HStack {
                Text(library.settings.extraFolder ?? "None")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") { chooseFolder() }
                if library.settings.extraFolder != nil {
                    Button("Remove") { library.setExtraFolder(nil) }
                }
            }
        }
        LabeledContent("Found") {
            HStack {
                Text(library.scripts.count == 1 ? "1 script command" : "\(library.scripts.count) script commands")
                    .foregroundStyle(.secondary)
                Button("Reload") { library.rescan() }
                    .disabled(library.scanning)
            }
        }
        ForEach(Array(library.problems.enumerated()), id: \.offset) { _, problem in
            Label {
                Text("\(problem.file): \(problem.message)").font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        Text("Scripts in any language with Raycast's metadata comments (# @raycast.title, # @raycast.mode…) show up "
             + "in the launcher. Type arguments after the title (“weather berlin”).")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder of script commands (Raycast's work too)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.setExtraFolder(url)
    }
}

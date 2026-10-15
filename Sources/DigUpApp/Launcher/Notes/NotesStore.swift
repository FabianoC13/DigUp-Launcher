import AppKit
import DigUpKit
import Observation

/// A note: a Markdown file in `Launcher.directory/Notes`, named by its id. Its first line with text is its title.
struct NoteFile: Identifiable, Equatable, Sendable {
    /// A UUID, the file's name without ".md".
    let id: String
    var text: String
    var created: Date
    var modified: Date

    var title: String { NotesText.title(of: text) }
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The notes on disk, in memory for searching: read off the main thread at launch (and again when a while has
/// passed, for edits made elsewhere), written atomically a moment after each change.
@Observable
final class NotesStore {
    static let shared = NotesStore()

    /// What isn't in the notes themselves: pins, the order notes were opened in, the window's font.
    struct State: Codable, Equatable {
        var pinned: [String] = []
        /// Most recently opened first.
        var recent: [String] = []
        var monospaced = false
        var fontSize: Double = 14
    }

    /// Most recently changed first.
    private(set) var notes: [NoteFile] = []
    private(set) var state = State()
    private(set) var loaded = false
    @ObservationIgnored private var lastLoad = Date.distantPast
    @ObservationIgnored private var loading = false
    /// Notes changed in memory and not yet written: a reload keeps these.
    @ObservationIgnored private var unsaved: Set<String> = []
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]

    static var folder: URL { ProductivityFiles.folder("Notes") }
    private static var stateFile: URL { folder.appendingPathComponent(".state.json") }
    static let fontSizes: ClosedRange<Double> = 10...28

    func file(_ id: String) -> URL { Self.folder.appendingPathComponent(id + ".md") }

    func start() {
        state = ProductivityFiles.load(State.self, from: Self.stateFile) ?? State()
        reload()
    }

    /// Reads the folder again when the last read is a while ago (a note edited in another app).
    func reloadIfStale(after seconds: TimeInterval = 10) {
        if Date().timeIntervalSince(lastLoad) > seconds { reload() }
    }

    func reload() {
        guard !loading else { return }
        loading = true
        let folder = Self.folder
        Task {
            let found = await Task.detached(priority: .utility) { Self.read(folder) }.value
            let keep = notes.filter { unsaved.contains($0.id) }
            var merged = found.filter { note in !keep.contains { $0.id == note.id } } + keep
            merged.sort { $0.modified > $1.modified }
            notes = merged
            state.pinned.removeAll { id in !merged.contains { $0.id == id } }
            lastLoad = Date()
            loaded = true
            loading = false
        }
    }

    nonisolated private static func read(_ folder: URL) -> [NoteFile] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? Date()
            return NoteFile(id: url.deletingPathExtension().lastPathComponent, text: text,
                            created: values?.creationDate ?? modified, modified: modified)
        }
    }

    func note(_ id: String) -> NoteFile? {
        notes.first { $0.id == id }
    }

    /// The note opened last that's still there.
    var lastOpened: NoteFile? {
        for id in state.recent { if let note = note(id) { return note } }
        return notes.first
    }

    var pinned: [NoteFile] { state.pinned.compactMap { note($0) } }

    func isPinned(_ id: String) -> Bool { state.pinned.contains(id) }

    // MARK: Changes

    /// A new note (written once it has text).
    func create(text: String = "") -> NoteFile {
        let now = Date()
        let note = NoteFile(id: UUID().uuidString, text: text, created: now, modified: now)
        notes.insert(note, at: 0)
        if !note.isBlank { save(note.id, after: .zero) }
        return note
    }

    /// New text for a note: kept now, written after `delay` (typing goes on).
    func update(_ id: String, text: String, delay: Duration = .milliseconds(500)) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].modified = Date()
        let note = notes.remove(at: index)
        notes.insert(note, at: 0)
        save(id, after: delay)
    }

    /// Writes a note after `delay`; a blank note is never written (and its file goes, if it had one).
    func save(_ id: String, after delay: Duration) {
        unsaved.insert(id)
        saveTasks[id]?.cancel()
        saveTasks[id] = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            writeNow(id)
        }
    }

    /// Writes any pending change of a note at once (the window closes, another note opens).
    func flush(_ id: String) {
        guard unsaved.contains(id) else { return }
        saveTasks[id]?.cancel()
        writeNow(id)
    }

    private func writeNow(_ id: String) {
        saveTasks[id] = nil
        unsaved.remove(id)
        guard let note = note(id) else { return }
        if note.isBlank {
            try? FileManager.default.removeItem(at: file(id))   // emptied: nothing worth keeping
        } else {
            ProductivityFiles.write(Data(note.text.utf8), to: file(id))
        }
    }

    /// Drops a note that was left empty (a new note never typed in).
    func discardIfBlank(_ id: String) {
        guard let note = note(id), note.isBlank else { return }
        saveTasks[id]?.cancel()
        unsaved.remove(id)
        notes.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: file(id))
        forget(id)
    }

    /// Moves a note's file to the Trash (it can be put back from there).
    func delete(_ id: String) {
        saveTasks[id]?.cancel()
        unsaved.remove(id)
        notes.removeAll { $0.id == id }
        let url = file(id)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                log("notes: couldn't move a note to the Trash (\(error.localizedDescription))")
            }
        }
        forget(id)
    }

    private func forget(_ id: String) {
        state.pinned.removeAll { $0 == id }
        state.recent.removeAll { $0 == id }
        saveState()
    }

    func togglePin(_ id: String) {
        if let index = state.pinned.firstIndex(of: id) {
            state.pinned.remove(at: index)
        } else {
            state.pinned.append(id)
        }
        saveState()
    }

    /// Remembers that a note was opened (for Open Last Note).
    func opened(_ id: String) {
        state.recent.removeAll { $0 == id }
        state.recent.insert(id, at: 0)
        if state.recent.count > 50 { state.recent.removeLast(state.recent.count - 50) }
        saveState()
    }

    func setMonospaced(_ on: Bool) {
        state.monospaced = on
        saveState()
    }

    func setFontSize(_ size: Double) {
        state.fontSize = min(Self.fontSizes.upperBound, max(Self.fontSizes.lowerBound, size))
        saveState()
    }

    private func saveState() {
        ProductivityFiles.save(state, to: Self.stateFile)
    }

    // MARK: Export

    /// Saves a copy of a note where you choose, as Markdown or plain text.
    func export(_ note: NoteFile) {
        let panel = NSSavePanel()
        panel.title = "Export Note"
        panel.nameFieldStringValue = ScriptCommandLine.fileName(forTitle: note.title, extension: "md")
        let format = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        format.addItems(withTitles: ["Markdown", "Plain Text"])
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, format])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        let switcher = NotesFormatSwitcher(panel: panel)
        format.target = switcher
        format.action = #selector(NotesFormatSwitcher.changed(_:))
        bringAppToFront()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let plain = format.indexOfSelectedItem == 1
        let text = plain ? NotesText.plainText(fromMarkdown: note.text) : note.text
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            ProductivityHUD.show("Exported “\(note.title)”", symbol: "square.and.arrow.up")
        } catch {
            ProductivityHUD.show("Couldn't export: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
        withExtendedLifetime(switcher) {}
    }
}

/// Keeps the save panel's file extension in step with the chosen format.
private final class NotesFormatSwitcher: NSObject {
    weak var panel: NSSavePanel?

    init(panel: NSSavePanel) {
        self.panel = panel
    }

    @objc func changed(_ sender: NSPopUpButton) {
        guard let panel else { return }
        let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = name + (sender.indexOfSelectedItem == 1 ? ".txt" : ".md")
    }
}

import AppKit
import DigUpKit
import Observation
import UniformTypeIdentifiers

/// The snippets and their settings, in Launcher.directory/Snippets: snippets.json and settings.json.
@Observable
final class SnippetStore {
    static let shared = SnippetStore()

    struct Settings: Codable, Equatable {
        /// Typing a keyword anywhere replaces it with the snippet (needs Accessibility).
        var expansionEnabled = true
        var trigger = SnippetKeywordMatcher.Trigger.immediately
        /// Off: a keyword expands only as a word of its own.
        var expandWithinWords = true

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Settings()
            expansionEnabled = try container.decodeIfPresent(Bool.self, forKey: .expansionEnabled) ?? defaults.expansionEnabled
            trigger = (try? container.decodeIfPresent(SnippetKeywordMatcher.Trigger.self, forKey: .trigger)) ?? defaults.trigger
            expandWithinWords = try container.decodeIfPresent(Bool.self, forKey: .expandWithinWords) ?? defaults.expandWithinWords
        }
    }

    private(set) var snippets: [Snippet] = []
    var settings = Settings() {
        didSet {
            guard settings != oldValue else { return }
            write(settings, to: settingsURL)
            changed()
        }
    }

    /// Called after the snippets or settings changed: the expander takes the new keywords.
    @ObservationIgnored var onChange: [() -> Void] = []

    static var directory: URL { Launcher.directory.appendingPathComponent("Snippets", isDirectory: true) }
    private var snippetsURL: URL { Self.directory.appendingPathComponent("snippets.json") }
    private var settingsURL: URL { Self.directory.appendingPathComponent("settings.json") }

    func load() {
        if let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = saved
        }
        if let data = try? Data(contentsOf: snippetsURL) {
            do {
                snippets = try Self.decoder.decode([Snippet].self, from: data)
            } catch {
                log("snippets: couldn't read snippets.json: \(error.localizedDescription)")
            }
        }
        log("snippets: \(snippets.count) snippets, \(snippets.filter { $0.keyword != nil }.count) with keywords")
    }

    // MARK: Reading

    func snippet(_ id: String) -> Snippet? { snippets.first { $0.id == id } }

    /// Another snippet's text by name ({snippet name="…"}).
    func text(named name: String) -> String? {
        snippets.first { $0.name == name }?.text ?? snippets.first { $0.name.lowercased() == name.lowercased() }?.text
    }

    /// Pinned first, then by name.
    var sorted: [Snippet] {
        snippets.sorted {
            $0.pinned != $1.pinned ? $0.pinned
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Changing

    /// Adds the snippet, or replaces the one with its id.
    func save(_ snippet: Snippet) {
        var snippet = snippet
        snippet.modified = Date()
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        persist()
    }

    @discardableResult
    func duplicate(_ id: String) -> Snippet? {
        guard let original = snippet(id) else { return nil }
        let copy = SnippetLibrary.duplicate(original, in: snippets)
        snippets.append(copy)
        persist()
        return copy
    }

    func delete(_ id: String) {
        snippets.removeAll { $0.id == id }
        persist()
    }

    func togglePin(_ id: String) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[index].pinned.toggle()
        persist()
    }

    private func persist() {
        do {
            write(try Self.encoder.encode(snippets), to: snippetsURL)
        } catch {
            log("snippets: couldn't encode the snippets: \(error.localizedDescription)")
        }
        changed()
    }

    private func changed() {
        for observer in onChange { observer() }
    }

    private func write(_ settings: Settings, to url: URL) {
        guard let data = try? Self.encoder.encode(settings) else { return }
        write(data, to: url)
    }

    /// Small files: written right away, atomically.
    private func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log("snippets: couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Import and export

    /// Asks for a JSON file (Raycast's export, or DigUp's) and adds its snippets. Returns what happened, for a message.
    func importFromFile() -> String? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Import Snippets"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let result = try SnippetLibrary.importing(try Data(contentsOf: url), into: snippets)
            snippets = result.snippets
            persist()
            var message = result.added == 1 ? "Imported 1 snippet." : "Imported \(result.added) snippets."
            if result.duplicates > 0 { message += " \(result.duplicates) were already there." }
            if result.keywordsDropped > 0 {
                message += " \(result.keywordsDropped) came without their keyword (already used or not valid)."
            }
            log("snippets: imported \(result.added) from \(url.lastPathComponent)")
            return message
        } catch let error as SnippetLibrary.ImportError {
            return error.description
        } catch {
            return "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Saves every snippet as a JSON array of {name, text, keyword} (the format Raycast imports).
    func exportToFile() -> String? {
        guard !snippets.isEmpty else { return "There are no snippets to export yet." }
        NSApp.activate()
        let panel = NSSavePanel()
        panel.title = "Export Snippets"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Snippets.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try SnippetLibrary.exportData(sorted).write(to: url, options: .atomic)
            log("snippets: exported \(snippets.count)")
            return snippets.count == 1 ? "Exported 1 snippet." : "Exported \(snippets.count) snippets."
        } catch {
            return "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// A message after import or export, in front of everything.
    static func tell(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

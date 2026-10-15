import AppKit
import DigUpKit
import UniformTypeIdentifiers

/// Export Launcher Data / Import Launcher Data: favorites, aliases, hotkeys, quicklinks and the snippets file as one
/// JSON file (`QuicklinksBackup`). Importing adds what the file has to what's here; nothing is replaced.
enum QuicklinksBackupFiles {
    /// The Snippets feature's file, carried along as it is.
    private static var snippetsFile: URL {
        Launcher.directory.appendingPathComponent("Snippets", isDirectory: true).appendingPathComponent("snippets.json")
    }

    /// Asks where to save, then writes the backup there. Nil when cancelled, else what happened (for an alert).
    static func export(launcher: Launcher, store: QuicklinksStore) async -> (title: String, detail: String)? {
        let panel = NSSavePanel()
        panel.title = "Export Launcher Data"
        panel.message = "Quicklinks, favorites, aliases, hotkeys and snippets, in one file"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "DigUp Launcher \(day).json"
        bringAppToFront()
        guard panel.runModal() == .OK, let file = panel.url else { return nil }

        let usage = launcher.usage
        let links = store.links
        let snippetsFile = self.snippetsFile
        let outcome: Result<QuicklinksBackup, Error> = await Task.detached(priority: .userInitiated) {
            do {
                var snippets: QuicklinksJSON?
                if let data = try? Data(contentsOf: snippetsFile) {
                    snippets = try? JSONDecoder().decode(QuicklinksJSON.self, from: data)
                }
                let backup = QuicklinksBackup(exported: Date(), favorites: usage.favorites, aliases: usage.aliases,
                                              hotkeys: usage.hotkeys, quicklinks: links, snippets: snippets)
                let data = try QuicklinksBackup.encoder().encode(backup)
                try data.write(to: file, options: .atomic)
                return .success(backup)
            } catch {
                return .failure(error)
            }
        }.value
        switch outcome {
        case .success(let backup):
            log("quicklinks: exported launcher data")
            var parts = [count(backup.quicklinks.count, "quicklink"), count(backup.favorites.count, "favorite"),
                         count(backup.aliases.count, "alias", "aliases"), count(backup.hotkeys.count, "hotkey")]
            if case .array(let entries) = backup.snippets {
                parts.append(count(entries.count, "snippet"))
            } else if backup.snippets != nil {
                parts.append("the snippets")
            }
            return ("Exported to “\(file.lastPathComponent)”", list(parts) + ".")
        case .failure(let error):
            log("quicklinks: export failed: \(error.localizedDescription)")
            return ("Couldn't export", error.localizedDescription)
        }
    }

    /// Asks for a backup (DigUp's, or a Raycast quicklinks export) and adds what it has. Nil when cancelled.
    static func importFile(launcher: Launcher, store: QuicklinksStore) async -> (title: String, detail: String)? {
        let panel = NSOpenPanel()
        panel.title = "Import Launcher Data"
        panel.message = "A DigUp launcher export, or a JSON list of quicklinks"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        bringAppToFront()
        guard panel.runModal() == .OK, let file = panel.url else { return nil }

        let read: Result<QuicklinksBackup, Error> = await Task.detached(priority: .userInitiated) {
            Result { try QuicklinksBackup.read(Data(contentsOf: file)) }
        }.value
        let backup: QuicklinksBackup
        switch read {
        case .success(let found):
            backup = found
        case .failure(let error):
            log("quicklinks: can't import \(file.lastPathComponent): \(error)")
            return ("“\(file.lastPathComponent)” isn't a launcher export",
                    "It should be a file from Export Launcher Data, or a JSON list of quicklinks with a name and a link.")
        }
        return await merge(backup, launcher: launcher, store: store)
    }

    /// Adds the backup to what's here, and says what it added.
    static func merge(_ backup: QuicklinksBackup, launcher: Launcher,
                      store: QuicklinksStore) async -> (title: String, detail: String) {
        var summary = QuicklinksBackup.Summary()
        var links = store.links
        backup.mergeQuicklinks(into: &links, summary: &summary)
        if summary.quicklinksAdded > 0 { store.replaceAll(links) }
        launcher.personalize { backup.mergeUsage(into: &$0, summary: &summary) }
        var snippetsNote = ""
        if let snippets = backup.snippets {
            let file = snippetsFile
            let added: Result<Int, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let existing = (try? Data(contentsOf: file)).flatMap {
                        try? JSONDecoder().decode(QuicklinksJSON.self, from: $0)
                    }
                    let (merged, added) = QuicklinksJSON.merge(existing, with: snippets)
                    guard added > 0 else { return 0 }
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                    try encoder.encode(merged).write(to: file, options: .atomic)
                    return added
                }
            }.value
            switch added {
            case .success(let count):
                summary.snippetsAdded = count
                if count > 0 { snippetsNote = " Quit and reopen DigUp to see the new snippets." }
            case .failure(let error):
                log("quicklinks: can't merge snippets: \(error.localizedDescription)")
                snippetsNote = " The snippets couldn't be added (\(error.localizedDescription))."
            }
        }
        log("quicklinks: imported \(summary.quicklinksAdded) quicklinks, \(summary.aliasesAdded) aliases, "
            + "\(summary.hotkeysAdded) hotkeys, \(summary.snippetsAdded) snippets")
        var added = [count(summary.quicklinksAdded, "quicklink"), count(summary.favoritesAdded, "favorite"),
                     count(summary.aliasesAdded, "alias", "aliases"), count(summary.hotkeysAdded, "hotkey")]
        if backup.snippets != nil { added.append(count(summary.snippetsAdded, "snippet")) }
        var skipped: [String] = []
        if summary.quicklinksSkipped > 0 { skipped.append(count(summary.quicklinksSkipped, "quicklink")) }
        if summary.aliasesSkipped > 0 { skipped.append(count(summary.aliasesSkipped, "alias", "aliases")) }
        if summary.hotkeysSkipped > 0 { skipped.append(count(summary.hotkeysSkipped, "hotkey")) }
        var detail = "Added " + list(added) + "."
        if !skipped.isEmpty {
            detail += " Left out " + list(skipped) + " already here or taken by another item."
        }
        return ("Imported", detail + snippetsNote)
    }

    private static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) " + (number == 1 ? singular : plural ?? singular + "s")
    }

    /// "a, b and c".
    private static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
}

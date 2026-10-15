import AppKit
import DigUpKit
import SwiftUI

/// Clipboard History's list: Pinned, Today, Yesterday, This Week, Earlier. ↩ pastes into the app you came from, ⌘↩
/// copies, ⌥↩ pastes as plain text. Typing filters; a first word like "images" or "links" keeps one kind.
final class ClipboardHistoryMode: LauncherMode {
    let title = "Clipboard History"
    let placeholder = "Search what you copied… (try “images” or “links”)"
    let icon: LauncherIcon = .symbol("doc.on.clipboard")
    var keysHint: String? { "↩ Paste   ⌘↩ Copy   ⌥1–9 Paste   ⌘1–9 Copy   ⌘K Actions" }
    var statusHint: String? {
        if store.settings.paused { return "Recording paused" }
        let count = store.entries.count
        return count == 1 ? "1 entry" : "\(count) entries"
    }

    private let store = ClipboardStore.shared

    /// Counted once per text: characters, words, lines, and whether it reads as code.
    private struct TextStats {
        var characters: Int
        var words: Int
        var lines: Int
        var code: Bool
    }

    private static var stats: [String: TextStats] = [:]

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let now = Date()
        let search = ClipboardSearch(parsing: query.raw)
        var items: [LauncherItem] = []
        // ⌘1…⌘9 / ⌥1…⌥9 (as in Maccy) and fn+1…fn+9 anywhere count copies newest first, pinned or not.
        let numbers = Dictionary(uniqueKeysWithValues: store.byRecency.prefix(9).enumerated().map { ($1.id, $0 + 1) })
        for group in ClipboardHistoryRules.ordered(store.entries, now: now) {
            let section = LauncherSection.named(group.section.title, order: group.section.rawValue)
            for entry in group.entries
            where search.isEmpty || ClipboardHistoryRules.matches(entry, searchText: store.searchText(of: entry), search: search) {
                items.append(item(for: entry, section: section, now: now, number: numbers[entry.id]))
            }
        }
        return items
    }

    // MARK: Keys

    /// Maccy's keys: ⌘1…⌘9 copy, ⌥1…⌥9 paste, ⌥⇧1…⌥⇧9 paste as plain text the nth newest copy; ⌥⌫ deletes the selected
    /// entry.
    func handle(_ event: NSEvent, query: String, context: LauncherContext) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if event.keyCode == 51, flags == .option, let id = context.selectedItemID, id.hasPrefix("clip:") {
            store.delete(String(id.dropFirst(5)))
            context.refresh()
            context.flash("Deleted")
            return true
        }
        guard let number = ClipboardNumberKeys.digitKeys[Int64(event.keyCode)],
              [.command, .option, [.option, .shift]].contains(flags) else { return false }
        let recent = store.byRecency
        guard recent.indices.contains(number - 1) else {
            NSSound.beep()
            return true
        }
        let entry = recent[number - 1]
        guard store.write(entry, plainText: flags == [.option, .shift]) else {
            Self.missing()
            return true
        }
        if flags == .command {
            context.hide()
        } else {
            context.pasteClipboard()
        }
        return true
    }

    // MARK: Rows

    private func item(for entry: ClipboardEntry, section: LauncherSection, now: Date, number: Int?) -> LauncherItem {
        let when = ClipboardHistoryRules.relativeTime(entry.copied, now: now)
            ?? entry.copied.formatted(date: .abbreviated, time: .omitted)
        return LauncherItem(
            id: "clip:\(entry.id)", title: entry.title,
            subtitle: [entry.sourceName, when].compactMap { $0 }.joined(separator: " · "),
            icon: icon(for: entry),
            accessory: [entry.kind == .text ? nil : entry.kind.title, number.map { "⌥\($0)" }].compactMap { $0 }
                .joined(separator: "  "),
            section: section, score: 0.5,
            actions: actions(for: entry), detail: detail(for: entry), metadata: metadata(for: entry),
            tracksUsage: false)
    }

    private func textStats(_ entry: ClipboardEntry) -> TextStats {
        if let cached = Self.stats[entry.id] { return cached }
        let stats = TextStats(characters: entry.text.count, words: ClipboardClassifier.wordCount(entry.text),
                              lines: ClipboardClassifier.lineCount(entry.text),
                              code: ClipboardClassifier.looksLikeCode(entry.text))
        Self.stats[entry.id] = stats
        return stats
    }

    private func icon(for entry: ClipboardEntry) -> LauncherIcon {
        switch entry.kind {
        case .text:
            return .symbol(textStats(entry).code ? "chevron.left.forwardslash.chevron.right" : "doc.plaintext")
        case .link: return .symbol("link", .blue)
        case .email: return .symbol("envelope", .blue)
        case .color:
            guard let color = ClipboardColor(parsing: entry.text) else { return .symbol("paintpalette") }
            return .color(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
        case .image:
            return store.thumbnail(of: entry).map { .image($0) } ?? .symbol("photo")
        case .files:
            if entry.files.count == 1 { return .file(URL(fileURLWithPath: entry.files[0])) }
            return .symbol("doc.on.doc")
        }
    }

    private func detail(for entry: ClipboardEntry) -> LauncherDetail {
        switch entry.kind {
        case .text: return .text(entry.text, monospaced: textStats(entry).code)
        case .link, .email: return .text(entry.text)
        case .color:
            guard let color = ClipboardColor(parsing: entry.text) else { return .text(entry.text) }
            return .custom(AnyView(ClipboardColorPreview(color: color)))
        case .image: return .image(store.imageURL(entry.id))
        case .files:
            if entry.files.count == 1 { return .file(URL(fileURLWithPath: entry.files[0])) }
            return .text(entry.files.joined(separator: "\n"))
        }
    }

    private func metadata(for entry: ClipboardEntry) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            ("Source", entry.sourceName ?? "Unknown"),
            ("Copied", entry.copied.formatted(date: .abbreviated, time: .shortened)),
        ]
        if entry.timesCopied > 1 { rows.append(("Times Copied", "\(entry.timesCopied)")) }
        switch entry.kind {
        case .text, .email:
            if entry.textInFile, let bytes = entry.byteCount {
                rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
            } else {
                let stats = textStats(entry)
                rows.append(("Characters", stats.characters.formatted()))
                rows.append(("Words", stats.words.formatted()))
                if stats.lines > 1 { rows.append(("Lines", stats.lines.formatted())) }
            }
        case .link:
            if let host = ClipboardClassifier.link(in: entry.text)?.host() { rows.append(("Host", host)) }
            rows.append(("Characters", entry.text.count.formatted()))
        case .color:
            if let color = ClipboardColor(parsing: entry.text) {
                rows += [("Hex", color.hex), ("RGB", color.rgb), ("HSL", color.hsl)]
            }
        case .image:
            if let width = entry.imageWidth, let height = entry.imageHeight {
                rows.append(("Dimensions", "\(width) × \(height)"))
            }
            if let bytes = entry.byteCount {
                rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
            }
        case .files:
            rows.append(("Files", entry.files.count.formatted()))
            if entry.files.count == 1 { rows.append(("Path", (entry.files[0] as NSString).abbreviatingWithTildeInPath)) }
        }
        return rows
    }

    // MARK: Actions

    private func actions(for entry: ClipboardEntry) -> [LauncherAction] {
        let store = store
        let id = entry.id
        var actions = [
            LauncherAction(id: "paste", title: "Paste", symbol: "doc.on.clipboard") { context in
                guard let entry = store.entry(id), store.write(entry) else { return Self.missing() }
                context.pasteClipboard()
            },
            LauncherAction(id: "copy", title: "Copy to Clipboard", symbol: "doc.on.doc") { _ in
                guard let entry = store.entry(id), store.write(entry) else { return Self.missing() }
            },
        ]
        if entry.kind == .files || (entry.kind.isTextual && !entry.richTypes.isEmpty) {
            actions.append(LauncherAction(id: "paste-plain", title: "Paste as Plain Text", symbol: "textformat",
                                          shortcut: LauncherShortcut("return", [.option])) { context in
                guard let entry = store.entry(id), store.write(entry, plainText: true) else { return Self.missing() }
                context.pasteClipboard()
            })
        }
        actions += openActions(for: entry)
        if entry.kind == .color, let color = ClipboardColor(parsing: entry.text) {
            for (format, value) in [("HEX", color.hex), ("RGB", color.rgb), ("HSL", color.hsl)] where value != entry.text {
                actions.append(LauncherAction(id: "copy-\(format.lowercased())", title: "Copy as \(format)",
                                              symbol: "eyedropper") { context in
                    context.copy(value, flash: nil)
                })
            }
        }
        actions += [
            LauncherAction(id: "pin", title: entry.pinned ? "Unpin" : "Pin", symbol: entry.pinned ? "pin.slash" : "pin",
                           shortcut: LauncherShortcut("p", .option), keepsPanelOpen: true) { context in
                store.togglePin(id)
                context.refresh()
                context.flash(store.entry(id)?.pinned == true ? "Pinned" : "Unpinned")
            },
            LauncherAction(id: "rename", title: "Rename…", symbol: "pencil", shortcut: LauncherShortcut("r", .command),
                           keepsPanelOpen: true) { context in
                guard let entry = store.entry(id),
                      let name = context.prompt("Rename Entry", message: "Shown instead of its first line. Leave empty to go back to it.",
                                                initial: entry.customTitle ?? "", button: "Rename") else { return }
                store.rename(id, to: name)
                context.refresh()
            },
            LauncherAction(id: "delete", title: "Delete Entry", symbol: "trash", shortcut: .deleteItem,
                           style: .destructive, keepsPanelOpen: true) { context in
                store.delete(id)
                context.refresh()
                context.flash("Deleted")
            },
            LauncherAction(id: "delete-all", title: "Delete All Entries…", symbol: "trash.slash",
                           shortcut: LauncherShortcut("x", [.control, .shift]), style: .destructive,
                           keepsPanelOpen: true) { context in
                let count = store.entries.filter { !$0.pinned }.count
                guard count > 0 else { return context.flash("Only pinned entries left") }
                guard context.confirm("Delete \(count == 1 ? "1 entry" : "\(count) entries") from Clipboard History?",
                                      message: "Pinned entries stay. This can't be undone.", button: "Delete All",
                                      destructive: true) else { return }
                store.deleteAllUnpinned()
                context.refresh()
            },
        ]
        return actions
    }

    private func openActions(for entry: ClipboardEntry) -> [LauncherAction] {
        let open = LauncherShortcut("o", .command)
        switch entry.kind {
        case .link:
            guard let url = ClipboardClassifier.link(in: entry.text) else { return [] }
            return [LauncherAction(id: "open", title: "Open Link", symbol: "safari", shortcut: open) { context in
                context.open(url)
            }]
        case .email:
            guard let address = ClipboardClassifier.email(in: entry.text),
                  let url = URL(string: "mailto:\(address)") else { return [] }
            return [LauncherAction(id: "open", title: "Compose Email", symbol: "envelope", shortcut: open) { context in
                context.open(url)
            }]
        case .image:
            let url = store.imageURL(entry.id)
            return [LauncherAction(id: "open", title: "Open Image", symbol: "photo", shortcut: open) { context in
                context.open(url)
            }]
        case .files:
            let urls = entry.files.map { URL(fileURLWithPath: $0) }
            return [
                LauncherAction(id: "open", title: urls.count == 1 ? "Open File" : "Open Files", symbol: "arrow.up.forward.app",
                               shortcut: open) { context in
                    for url in urls { context.open(url) }
                },
                LauncherAction(id: "reveal", title: "Show in Finder", symbol: "folder",
                               shortcut: LauncherShortcut("f", [.command, .shift])) { _ in
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                },
            ]
        case .text, .color:
            return []
        }
    }

    /// The entry or its file is gone (deleted from another window, or the image file was removed).
    private static func missing() {
        log("clipboard: an entry's data is gone")
        NSSound.beep()
    }
}

/// A copied color, big, with its values.
private struct ClipboardColorPreview: View {
    let color: ClipboardColor

    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
                .frame(height: 150)
            VStack(spacing: 4) {
                Text(color.hex).font(.system(.title3, design: .monospaced).weight(.semibold))
                Text(color.rgb).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Text(color.hsl).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

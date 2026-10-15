import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DigUpKit

/// Types a snippet out in the app in front: fills its placeholders (asking for its {argument}s), pastes it through the
/// clipboard marked as passing (so Clipboard History leaves it out), moves the caret to its {cursor}, then puts back
/// what was on the clipboard.
enum SnippetPaster {
    /// Set on DigUp's own key presses, so text expansion doesn't read them as typing.
    nonisolated static let eventMarker: Int64 = 0x4469_6755_7053 // "DigUpS"
    /// How long the app gets to read the pasted text before the clipboard is put back.
    static let restoreDelay: Duration = .milliseconds(350)

    /// Pastes `snippet` into `target`. With `deleteCount` (text expansion) that many characters before the caret go
    /// first (the keyword); `suffix` is typed after it (the space that triggered it). False when nothing was pasted.
    @discardableResult
    static func paste(_ snippet: Snippet, into target: NSRunningApplication?, deleteCount: Int = 0,
                      suffix: String = "") async -> Bool {
        let store = SnippetStore.shared
        if deleteCount > 0 {
            post(CGKeyCode(kVK_Delete), count: deleteCount)
            try? await Task.sleep(for: .milliseconds(30))
        }
        var answers: [String: String] = [:]
        let arguments = SnippetPlaceholders.arguments(in: snippet.text) { store.text(named: $0) }
        if !arguments.isEmpty {
            guard let given = askArguments(arguments, snippet: snippet.name) else { return false }
            answers = given
        }
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            target.activate()
            try? await Task.sleep(for: .milliseconds(150))
        }
        let expansion = SnippetPlaceholders.expand(snippet.text, values: values(arguments: answers))
        let text = expansion.text + suffix
        let pasteboard = NSPasteboard.general

        guard Accessibility.isTrusted(prompt: true) else {
            // Can't press ⌘V: leave the text on the clipboard to paste by hand.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            log("snippets: no Accessibility permission; left the snippet on the clipboard")
            return false
        }

        let saved = savedItems()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let written = pasteboard.changeCount

        post(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        if let after = expansion.charactersAfterCursor {
            let back = after + suffix.count
            if back > 0 {
                try? await Task.sleep(for: .milliseconds(60))
                post(CGKeyCode(kVK_LeftArrow), count: back)
            }
        }
        try? await Task.sleep(for: restoreDelay)
        // Put the clipboard back, unless something was copied in the meantime.
        if pasteboard.changeCount == written {
            restore(saved)
            ClipboardStore.shared.ignoreCurrentPasteboard()
        }
        return true
    }

    /// What the placeholders read: the clipboard (and Clipboard History for {clipboard offset=n}), the selection,
    /// other snippets, the arguments given.
    static func values(arguments: [String: String] = [:]) -> SnippetPlaceholderValues {
        SnippetPlaceholderValues(clipboard: { clipboardText(at: $0) }, selection: { selectedText() },
                                 snippet: { SnippetStore.shared.text(named: $0) }, arguments: arguments)
    }

    /// The text copied `offset` copies ago: 0 is the clipboard now, 1 the copy before (from Clipboard History)…
    static func clipboardText(at offset: Int) -> String? {
        let current = NSPasteboard.general.string(forType: .string)
        if offset == 0 { return current }
        let history = ClipboardStore.shared
        var texts = ClipboardStore.shared.entries.filter(\.kind.isTextual)
        if let current, texts.first?.text == ClipboardEntry.prefix(of: current) { texts.removeFirst() }
        guard offset - 1 < texts.count else { return nil }
        return history.fullText(of: texts[offset - 1])
    }

    /// The text selected in the focused app (Accessibility), or nil.
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString,
                                            &selected) == .success else { return nil }
        return selected as? String
    }

    // MARK: Arguments

    /// Asks for the snippet's {argument}s in one dialog; nil when cancelled.
    static func askArguments(_ arguments: [SnippetArgument], snippet name: String) -> [String: String]? {
        let alert = NSAlert()
        alert.messageText = "“\(name)”"
        alert.informativeText = arguments.count == 1 ? "This snippet needs a value." : "This snippet needs a few values."
        let rowHeight: CGFloat = 50
        let width: CGFloat = 280
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight * CGFloat(arguments.count)))
        var readers: [(key: String, value: () -> String)] = []
        var firstControl: NSView?
        for (index, argument) in arguments.enumerated() {
            let top = container.frame.height - rowHeight * CGFloat(index)
            let label = NSTextField(labelWithString: argument.name.prefix(1).uppercased() + argument.name.dropFirst())
            label.frame = NSRect(x: 0, y: top - 18, width: width, height: 16)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            container.addSubview(label)
            let frame = NSRect(x: 0, y: top - 44, width: width, height: 24)
            if argument.options.isEmpty {
                let field = NSTextField(frame: frame)
                field.stringValue = argument.defaultValue ?? ""
                field.placeholderString = argument.name
                container.addSubview(field)
                readers.append((argument.key, { field.stringValue }))
                firstControl = firstControl ?? field
            } else {
                let popup = NSPopUpButton(frame: frame, pullsDown: false)
                popup.addItems(withTitles: argument.options)
                if let value = argument.defaultValue, argument.options.contains(value) { popup.selectItem(withTitle: value) }
                container.addSubview(popup)
                readers.append((argument.key, { popup.titleOfSelectedItem ?? "" }))
                firstControl = firstControl ?? popup
            }
        }
        alert.accessoryView = container
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = firstControl
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Dictionary(readers.map { ($0.key, $0.value()) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Keys and the clipboard

    /// Key presses marked as DigUp's own (`eventMarker`).
    static func post(_ keyCode: CGKeyCode, flags: CGEventFlags = [], count: Int = 1) {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<max(count, 0) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
                event.flags = flags
                event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// Everything on the clipboard, every type of every item, to put back later.
    private static func savedItems() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ items: [[(NSPasteboard.PasteboardType, Data)]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restored = items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

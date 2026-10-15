import AppKit
import DigUpKit
import SwiftUI

/// The window that creates and edits snippets: name, keyword, text, and the placeholders it can hold. One at a time;
/// opening another snippet replaces what's in it.
final class SnippetEditor {
    static let shared = SnippetEditor()

    private var window: NSWindow?

    /// Opens `snippet` for editing, or a new one (with `text` filled in) when nil.
    func open(_ snippet: Snippet?, text: String = "") {
        let draft = SnippetDraft(snippet ?? Snippet(name: "", text: text))
        draft.isNew = snippet == nil
        let view = SnippetEditorView(draft: draft) { [weak self] in self?.close() }
        let window = self.window ?? makeWindow()
        window.title = snippet == nil ? "Create Snippet" : "Edit Snippet"
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 520, height: 460))
        if self.window == nil { window.center() }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 420, height: 360)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
    }
}

/// The snippet being edited, as the form's fields.
@Observable
final class SnippetDraft {
    let id: String
    let original: Snippet
    var isNew = false
    var name: String
    var keyword: String
    var text: String

    init(_ snippet: Snippet) {
        id = snippet.id
        original = snippet
        name = snippet.name
        keyword = snippet.keyword ?? ""
        text = snippet.text
    }

    var trimmedKeyword: String { keyword.trimmingCharacters(in: .whitespaces) }

    /// Why it can't be saved yet, or nil.
    var problem: String? {
        if text.isEmpty { return "Type the snippet's text." }
        if text.count > SnippetLibrary.maxTextLength {
            return "A snippet can hold up to \(SnippetLibrary.maxTextLength.formatted()) characters."
        }
        return SnippetLibrary.keywordProblem(trimmedKeyword, id: id, in: SnippetStore.shared.snippets)
    }

    var snippet: Snippet {
        var snippet = original
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.name = name.isEmpty ? SnippetLibrary.defaultName(for: text) : name
        snippet.keyword = trimmedKeyword.isEmpty ? nil : trimmedKeyword
        snippet.text = text
        return snippet
    }
}

/// The editor's form.
private struct SnippetEditorView: View {
    @Bindable var draft: SnippetDraft
    var close: () -> Void
    @State private var showsHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Name", text: $draft.name, prompt: Text(SnippetLibrary.defaultName(for: draft.text)))
                TextField("Keyword", text: $draft.keyword, prompt: Text("Optional, e.g. ;sig"))
            }
            .formStyle(.columns)
            HStack {
                Text("Text").font(.headline)
                Spacer()
                Menu("Insert Placeholder") {
                    ForEach(SnippetPlaceholders.help, id: \.placeholder) { entry in
                        Button("\(entry.placeholder)  \(entry.meaning)") { draft.text += entry.placeholder }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    showsHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("What placeholders do")
                .popover(isPresented: $showsHelp, arrowEdge: .bottom) { help }
            }
            TextEditor(text: $draft.text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                if let problem = draft.problem, !draft.text.isEmpty || !draft.isNew {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !draft.trimmedKeyword.isEmpty {
                    Text("Typing “\(draft.trimmedKeyword)” anywhere pastes this snippet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Create Snippet" : "Save", action: save)
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.problem != nil)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 360)
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Placeholders are filled in when the snippet is pasted.")
                .font(.callout.weight(.medium))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(SnippetPlaceholders.help, id: \.placeholder) { entry in
                    GridRow {
                        Text(entry.placeholder).font(.system(.caption, design: .monospaced))
                        Text(entry.meaning).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Text expansion types the snippet when you type its keyword (needs Accessibility).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 460)
    }

    private func save() {
        guard draft.problem == nil else { return }
        let snippet = draft.snippet
        SnippetStore.shared.save(snippet)
        log("snippets: saved a snippet (\(draft.isNew ? "new" : "edited"))")
        close()
    }
}

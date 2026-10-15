import AppKit
import DigUpKit
import SwiftUI

/// Settings → Launcher → Snippets: text expansion, the snippets themselves, import and export.
struct SnippetSettingsView: View {
    @Bindable var store: SnippetStore
    var expander: SnippetExpander
    @State private var trusted = Accessibility.isTrusted()

    var body: some View {
        Toggle(isOn: $store.settings.expansionEnabled) {
            Text("Expand keywords as you type")
            Text("Typing a snippet's keyword in any app replaces it with the snippet. Never in password fields.")
        }
        if store.settings.expansionEnabled {
            Picker("Expand", selection: $store.settings.trigger) {
                ForEach(SnippetKeywordMatcher.Trigger.allCases, id: \.self) { trigger in
                    Text(trigger.title).tag(trigger)
                }
            }
            Toggle(isOn: $store.settings.expandWithinWords) {
                Text("Expand inside words")
                Text("Off: a keyword expands only when it starts a word.")
            }
            if let problem = expander.problem ?? (trusted ? nil : "Text expansion and pasting need Accessibility.") {
                LabeledContent {
                    Button("Open Accessibility Settings…") {
                        _ = Accessibility.isTrusted(prompt: true)
                        Accessibility.openSettings()
                    }
                } label: {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if expander.running {
                Label("Watching for \(keywordCount == 1 ? "1 keyword" : "\(keywordCount) keywords")",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Snippets")
                Spacer()
                Button("Import…") { report(store.importFromFile()) }
                Button("Export…") { report(store.exportToFile()) }
                    .disabled(store.snippets.isEmpty)
                Button("Add Snippet…") { SnippetEditor.shared.open(nil) }
            }
            if store.snippets.isEmpty {
                Text("No snippets yet. Add one, or import Raycast's snippets export (a JSON file).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.sorted) { snippet in
                row(snippet)
            }
        }
        .onAppear { trusted = Accessibility.isTrusted() }
    }

    private var keywordCount: Int { store.snippets.filter { $0.keyword != nil }.count }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: 8) {
            Image(systemName: snippet.pinned ? "pin.fill" : "text.quote")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.name).lineLimit(1)
                Text(snippet.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let keyword = snippet.keyword {
                Text(keyword)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            Button {
                SnippetEditor.shared.open(snippet)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit “\(snippet.name)”")
            Button {
                delete(snippet)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Delete “\(snippet.name)”")
        }
    }

    private func delete(_ snippet: Snippet) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(snippet.name)”?"
        alert.informativeText = (snippet.keyword.map { "Typing “\($0)” won't expand anymore. " } ?? "")
            + "This can't be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.delete(snippet.id)
    }

    private func report(_ message: String?) {
        if let message { SnippetStore.tell(message) }
    }
}

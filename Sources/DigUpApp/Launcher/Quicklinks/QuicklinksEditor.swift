import AppKit
import DigUpKit
import SwiftUI
import UniformTypeIdentifiers

/// Create Quicklink / Edit Quicklink: its name, link, the app it opens in and a keyword, or one from the library.
enum QuicklinksEditor {
    /// Opens the editor for `record` (nil: a new one). `done` gets what was saved, nil when cancelled.
    static func show(_ record: QuicklinkRecord?, store: QuicklinksStore, launcher: Launcher,
                     done: @escaping (QuicklinkRecord?) -> Void) {
        var saved: QuicklinkRecord?
        QuicklinksWindow.show(key: "editor:\(record?.id ?? "new")",
                              title: record == nil ? "Create Quicklink" : "Edit Quicklink",
                              content: { close in
                                  QuicklinksEditorView(store: store, original: record) { result in
                                      saved = result
                                      close()
                                  }
                              },
                              onClose: { done(saved) })
    }
}

/// An app a link can open in, for the Open With menu.
private struct QuicklinksAppChoice: Identifiable, Equatable {
    let id: String   // bundle id
    let name: String
    let url: URL

    init?(_ url: URL) {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        id = bundleID
        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        self.url = url
    }
}

private struct QuicklinksEditorView: View {
    let store: QuicklinksStore
    let original: QuicklinkRecord?
    let finish: (QuicklinkRecord?) -> Void

    @State private var name: String
    @State private var link: String
    @State private var keyword: String
    @State private var openWith: String?
    @State private var apps: [QuicklinksAppChoice] = []
    /// What kind of link `apps` was looked up for (a scheme, or a file's type): the lookup runs only when it changes.
    @State private var appsKind = "\u{0}"

    init(store: QuicklinksStore, original: QuicklinkRecord?, finish: @escaping (QuicklinkRecord?) -> Void) {
        self.store = store
        self.original = original
        self.finish = finish
        _name = State(initialValue: original?.name ?? "")
        _link = State(initialValue: original?.link ?? "")
        _keyword = State(initialValue: original?.keyword ?? "")
        _openWith = State(initialValue: original?.openWith)
    }

    private var template: QuicklinkTemplate { QuicklinkTemplate(link.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// The link filled with stand-ins ("cats" for what's typed), to check it and show where it goes.
    private var sample: String {
        var arguments: [String: String] = [:]
        for argument in template.arguments { arguments[argument.key] = argument.defaultValue ?? "cats" }
        return template.filled(.init(arguments: arguments, clipboard: "copied text"))
    }

    private var destination: URL? { QuicklinkTemplate.destination(sample, home: NSHomeDirectory()) }

    private var linkProblem: String? {
        if link.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        return destination == nil ? "That isn't a web address, a file path or an app link" : nil
    }

    private var keywordProblem: String? {
        QuicklinkRecord.keywordProblem(keyword, for: original?.id ?? "", among: store.links)
    }

    private var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name it" }
        return linkProblem ?? keywordProblem
    }

    private var linkNote: String {
        if let linkProblem, !linkProblem.isEmpty { return linkProblem }
        guard destination != nil else {
            return "A web address, a search URL with {query} where the search goes, a file or folder path, or an "
                + "app link (slack://…)."
        }
        if let url = destination, url.isFileURL, !template.takesArgument,
           !FileManager.default.fileExists(atPath: url.path) {
            return "Nothing is at this path yet."
        }
        guard template.takesArgument else { return "Opens " + QuicklinkTemplate.display(sample) }
        let typed = name.trimmingCharacters(in: .whitespaces).isEmpty ? "its name" : "“\(name) cats”"
        let more = template.arguments.compactMap(\.label)
        return "Type \(typed) to open " + QuicklinkTemplate.display(sample)
            + (more.isEmpty ? "" : " (it asks for \(more.joined(separator: ", ")) too)")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Google Search"))
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Link", text: $link, prompt: Text("https://www.google.com/search?q={query}"))
                        Text(linkNote)
                            .font(.system(size: 11))
                            .foregroundStyle(linkProblem.map { $0.isEmpty ? Color.secondary : Color.red } ?? .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent("Open With") {
                        HStack(spacing: 6) {
                            Picker("Open With", selection: $openWith) {
                                Text(defaultAppTitle).tag(String?.none)
                                if !apps.isEmpty { Divider() }
                                ForEach(apps) { app in
                                    Label {
                                        Text(app.name)
                                    } icon: {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                    }
                                    .tag(String?.some(app.id))
                                }
                            }
                            .labelsHidden()
                            Button("Other…") { chooseApp() }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Keyword", text: $keyword, prompt: Text("Optional, like g"))
                        Text(keywordProblem ?? "Typed before what to search for: “g cats”.")
                            .font(.system(size: 11))
                            .foregroundStyle(keywordProblem == nil ? Color.secondary : Color.red)
                    }
                } footer: {
                    Text("Placeholders: {query} is what you type (percent-encoded), {argument name=\"to\" "
                         + "default=\"en\"} asks for another value, {clipboard} is the copied text, {date} {time} "
                         + "{uuid}; modifiers like {query | lowercase} or {query | raw}.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Menu("From Library") {
                    ForEach(QuicklinkRecord.library) { entry in
                        Button(entry.name) { use(entry) }
                    }
                }
                .fixedSize()
                .help("Ready-made quicklinks: web searches and folders")
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Create Quicklink" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 500)
        .onAppear { lookUpApps() }
        .onChange(of: link) { lookUpApps() }
    }

    private var defaultAppTitle: String {
        guard let url = destination, let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            return "Default App"
        }
        return "Default App (\(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")))"
    }

    /// The apps that open this kind of link, looked up again only when the kind changes (not on every keystroke).
    private func lookUpApps() {
        let url = destination
        let kind = url.map { $0.isFileURL ? "file:" + $0.pathExtension.lowercased() : $0.scheme?.lowercased() ?? "" } ?? ""
        guard kind != appsKind else { return }
        appsKind = kind
        var found = url.map { NSWorkspace.shared.urlsForApplications(toOpen: $0) }?.compactMap(QuicklinksAppChoice.init)
            ?? []
        var seen = Set<String>()
        found = found.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let openWith, !seen.contains(openWith),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: openWith),
           let choice = QuicklinksAppChoice(app) {
            found.insert(choice, at: 0)
        }
        apps = found
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = "The app this quicklink opens in"
        guard panel.runModal() == .OK, let url = panel.url, let choice = QuicklinksAppChoice(url) else { return }
        if !apps.contains(choice) { apps.insert(choice, at: 0) }
        openWith = choice.id
    }

    /// Fills the form from a library quicklink (its keyword only if no other quicklink has it).
    private func use(_ entry: QuicklinkRecord) {
        name = entry.name
        link = entry.link
        openWith = nil
        let free = entry.keyword.map { QuicklinkRecord.keywordProblem($0, for: original?.id ?? "", among: store.links) == nil }
        keyword = free == true ? entry.keyword ?? "" : ""
    }

    private func save() {
        guard problem == nil else { return }
        let record = QuicklinkRecord(id: original?.id ?? UUID().uuidString,
                                     name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     link: link.trimmingCharacters(in: .whitespacesAndNewlines),
                                     openWith: openWith, keyword: keyword)
        store.save(record)
        log("quicklinks: \(original == nil ? "created" : "edited") one")
        finish(record)
    }
}

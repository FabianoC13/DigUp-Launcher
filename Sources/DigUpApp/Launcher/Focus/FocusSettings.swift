import AppKit
import DigUpKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Launcher → Focus: the apps and websites a session blocks, and whether blocked apps quit or hide.
struct FocusSettingsView: View {
    @Bindable var focus: FocusController
    @State private var newDomain = ""
    @State private var domainProblem: String?

    var body: some View {
        if let session = focus.session {
            LabeledContent("Session") {
                HStack {
                    Text(session.goal.isEmpty ? "Running" : session.goal)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(focus.isPaused ? "Resume" : "Pause") { focus.isPaused ? focus.resume() : focus.pause() }
                    Button("Complete") { focus.complete() }
                }
            }
        }
        Toggle("Quit blocked apps instead of hiding them", isOn: Binding(
            get: { focus.blockList.quitApps }, set: { focus.setQuitApps($0) }))
        LabeledContent("Blocked apps") {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(FocusBlockList.appPresets, id: \.bundleID) { preset in
                    Toggle(preset.name, isOn: Binding(
                        get: { focus.blockList.apps.contains(preset.bundleID) },
                        set: { focus.setApp(preset.bundleID, blocked: $0) }))
                }
                ForEach(customApps, id: \.self) { bundleID in
                    HStack {
                        Text(Self.appName(bundleID))
                        Button { focus.setApp(bundleID, blocked: false) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Stop blocking")
                    }
                }
                Button("Add App…") { addApps() }
            }
        }
        LabeledContent("Blocked websites") {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(FocusBlockList.domainPresets, id: \.self) { domain in
                    Toggle(domain, isOn: Binding(
                        get: { focus.blockList.domains.contains(domain) },
                        set: { focus.setDomain(domain, blocked: $0) }))
                }
                ForEach(customDomains, id: \.self) { domain in
                    HStack {
                        Text(domain)
                        Button { focus.setDomain(domain, blocked: false) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Stop blocking")
                    }
                }
                HStack {
                    TextField("example.com", text: $newDomain)
                        .frame(width: 180)
                        .onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let domainProblem {
                    Text(domainProblem).font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        Text("While a session runs, blocked apps are hidden as they come to the front, and blocked websites (and their "
             + "subdomains) in Safari, Chrome, Arc, Brave, Edge, Vivaldi and Opera get a block page. Browsers ask once "
             + "for Automation permission.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var customApps: [String] {
        focus.blockList.apps.filter { id in !FocusBlockList.appPresets.contains { $0.bundleID == id } }
    }

    private var customDomains: [String] {
        focus.blockList.domains.filter { !FocusBlockList.domainPresets.contains($0) }
    }

    private func addDomain() {
        guard let domain = FocusDomains.normalize(newDomain) else {
            domainProblem = "“\(newDomain)” isn't a website's address"
            return
        }
        domainProblem = nil
        focus.setDomain(domain, blocked: true)
        newDomain = ""
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Block"
        panel.message = "Choose the apps a focus session hides."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            focus.setApp(bundleID, blocked: true)
        }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

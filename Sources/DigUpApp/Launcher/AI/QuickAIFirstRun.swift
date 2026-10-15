import AppKit
import DigUpKit
import SwiftUI

/// The first time DigUp runs without an AI key: a small window asks for one, with the providers to choose from
/// (DeepSeek first). "Later" leaves it for Settings → Launcher → Quick AI; it doesn't ask again either way.
enum QuickAIFirstRun {
    private static let askedKey = "quickAI.firstRunAsked"
    private static var controller: FirstRunWindowController?

    /// Asks once, after onboarding (if it's showing) is done.
    static func askIfNeeded(_ launcher: Launcher) {
        guard !AppController.offscreen, !AppSettings.defaults.bool(forKey: askedKey) else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            // Onboarding comes first: one window at a time.
            while launcher.panel?.appController.onboarding?.isVisible == true {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !QuickAIFeature.isSetUp, let app = launcher.panel?.appController else {
                AppSettings.defaults.set(true, forKey: askedKey)
                return
            }
            show(app)
        }
    }

    static func show(_ app: AppController) {
        let controller = Self.controller ?? FirstRunWindowController(app: app) { Self.controller = nil }
        Self.controller = controller
        AppSettings.defaults.set(true, forKey: askedKey)
        controller.show()
    }
}

private final class FirstRunWindowController: NSObject, NSWindowDelegate {
    private unowned let app: AppController
    private let onClose: () -> Void
    private var window: NSWindow?

    init(app: AppController, onClose: @escaping () -> Void) {
        self.app = app
        self.onClose = onClose
    }

    func show() {
        let window = self.window ?? {
            let view = FirstRunView { [weak self] in self?.window?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Set Up Quick AI"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            return window
        }()
        self.window = window
        app.present(window)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        app.windowClosed()
        onClose()
    }
}

private struct FirstRunView: View {
    let close: () -> Void
    @State private var providerID = QuickAIPreferences.shared.providerID
    @State private var key = ""
    @State private var baseURL = ""
    @State private var problem: String?

    private var preset: AIProviderPreset { AIProviderPreset.named(providerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Brand.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask AI from anywhere").font(.system(size: 16, weight: .semibold))
                    Text("Type a question in DigUp (⌘Space) and press Tab. Pick your provider and paste its API key; "
                         + "it's kept in your Mac's Keychain.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Provider").font(.system(size: 12, weight: .semibold))
            VStack(spacing: 2) {
                ForEach(AIProviderPreset.all, id: \.id) { option in
                    Button {
                        providerID = option.id
                        problem = nil
                    } label: {
                        HStack {
                            Image(systemName: providerID == option.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(providerID == option.id ? Color.accentColor : .secondary)
                            Text(option.name)
                            if option.id == AIProviderPreset.deepSeek.id {
                                Text("Recommended")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Brand.leaf.opacity(0.25)))
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(providerID == option.id ? Color.accentColor.opacity(0.12) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            if preset.keyOptional {
                TextField("Server address (\(preset.baseURL.isEmpty ? "https://…/v1" : preset.baseURL))",
                          text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            if preset.id != AIProviderPreset.ollama.id {
                SecureField(preset.keyOptional ? "API key (if it needs one)" : "API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            if let page = preset.keyPage.flatMap(URL.init(string:)) {
                Link("Get a \(preset.name) key ↗", destination: page).font(.system(size: 12))
            }
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                Text("You can change this later in Settings → Launcher → Quick AI.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Later", action: close)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var canSave: Bool {
        let typedKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if preset.keyOptional { return typedKey || !baseURL.trimmingCharacters(in: .whitespaces).isEmpty || preset.id == AIProviderPreset.ollama.id }
        return typedKey
    }

    private func save() {
        guard canSave else { return }
        let preferences = QuickAIPreferences.shared
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let status = QuickAIKeys.shared.save(trimmed, account: preset.id)
            guard status == errSecSuccess else {
                problem = "The Keychain didn't save it: \(QuickAIKeys.describe(status))"
                return
            }
            preferences.rememberKeyHint(trimmed, for: preset)
        }
        let address = baseURL.trimmingCharacters(in: .whitespaces)
        if preset.keyOptional {
            preferences.setBaseURL(address.isEmpty ? preset.baseURL : address, for: preset)
        }
        preferences.providerID = preset.id
        log("quick ai: set up with \(preset.name)")
        close()
    }
}

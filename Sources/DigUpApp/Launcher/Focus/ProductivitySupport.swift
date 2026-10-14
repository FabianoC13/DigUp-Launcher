import AppKit
import SwiftUI
import UniformTypeIdentifiers

// What My Schedule, Notes, Focus and Script Commands share: a HUD for after the panel hid, their JSON files, running a
// command-line tool (scripts, osascript) off the main thread, and opening a file in an editor.

/// A short message over everything, for what happens after the panel hid: a script's output, the end of a focus
/// session, an app a session blocked. (`LauncherContext.flash` shows in the panel's footer, so only while it's up.)
enum ProductivityHUD {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?
    static let maxWidth: CGFloat = 520

    /// In the panel's footer while it's up, else over everything.
    static func tell(_ text: String, symbol: String = "info.circle", context: LauncherContext?) {
        if let context, context.isPanelVisible {
            context.flash(text)
        } else {
            show(text, symbol: symbol)
        }
    }

    /// Shows `text` near the bottom of the screen with the pointer, for a couple of seconds.
    static func show(_ text: String, symbol: String? = nil, seconds: Double = 2.4) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let width = min(maxWidth, textWidth + (symbol == nil ? 0 : 24) + 34)
        let hosting = NSHostingView(rootView: HUDView(text: text, symbol: symbol).frame(width: width))
        let size = hosting.fittingSize
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + area.height * 0.14,
                              width: size.width, height: size.height), display: true)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    if panel.alphaValue < 0.01 { panel.orderOut(nil) }
                }
            }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private struct HUDView: View {
        let text: String
        let symbol: String?

        var body: some View {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The productivity features' JSON files, each in its folder under `Launcher.directory`.
enum ProductivityFiles {
    /// One queue, so saves land in the order they were made.
    private static let queue = DispatchQueue(label: "DigUp.launcher.productivity-files", qos: .utility)

    /// `Launcher.directory/<name>/`, created if it isn't there.
    static func folder(_ name: String) -> URL {
        let url = Launcher.directory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log("launcher: \(url.lastPathComponent) didn't read (\(error))")
            return nil
        }
    }

    /// Encoded now, written atomically off the main thread.
    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        write(data, to: url)
    }

    /// Writes atomically off the main thread, after any write queued before it.
    static func write(_ data: Data, to url: URL) {
        queue.async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                log("launcher: couldn't save \(url.lastPathComponent) (\(error.localizedDescription))")
            }
        }
    }
}

/// How a command-line tool's run went.
struct ProductivityRun: Sendable {
    var status: Int32 = -1
    var output = ""
    var errors = ""
    var timedOut = false
    /// It didn't start (not there, not executable): why.
    var failure: String?
    var duration: TimeInterval = 0

    var succeeded: Bool { failure == nil && !timedOut && status == 0 }
}

/// Runs command-line tools (script commands, osascript) on a background thread, with a time limit.
enum ProductivityProcess {
    /// Output past this is cut (a runaway script shouldn't fill the memory).
    nonisolated static let outputLimit = 2 << 20

    nonisolated static func run(_ executable: URL, arguments: [String] = [], environment: [String: String]? = nil,
                                directory: URL? = nil, timeout: TimeInterval = 60) async -> ProductivityRun {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments: arguments, environment: environment,
                                                           directory: directory, timeout: timeout))
            }
        }
    }

    nonisolated private static func runBlocking(_ executable: URL, arguments: [String], environment: [String: String]?,
                                                directory: URL?, timeout: TimeInterval) -> ProductivityRun {
        let started = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        var result = ProductivityRun()
        do {
            try process.run()
        } catch {
            result.failure = error.localizedDescription
            return result
        }
        let timedOut = ProductivityFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            // Still there a moment later: it ignored SIGTERM.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Both pipes at once: a tool that fills one while the other is read would wait forever.
        let errorData = ProductivityBuffer()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            errorData.set(readCapped(errors.fileHandleForReading))
        }
        let outputData = readCapped(output.fileHandleForReading)
        group.wait()
        process.waitUntilExit()
        watchdog.cancel()
        result.status = process.terminationStatus
        result.output = String(decoding: outputData, as: UTF8.self)
        result.errors = String(decoding: errorData.value, as: UTF8.self)
        result.timedOut = timedOut.isSet
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// Everything until the end, keeping the first `outputLimit` bytes (the rest is read and dropped, so the tool
    /// never blocks on a full pipe).
    nonisolated private static func readCapped(_ handle: FileHandle) -> Data {
        var data = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count < outputLimit { data.append(chunk.prefix(outputLimit - data.count)) }
        }
        return data
    }
}

/// A flag set from one thread and read from another.
nonisolated final class ProductivityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    init() {}

    func set() {
        lock.withLock { flag = true }
    }

    var isSet: Bool { lock.withLock { flag } }
}

/// Data handed from one thread to another.
nonisolated final class ProductivityBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    init() {}

    func set(_ value: Data) {
        lock.withLock { data = value }
    }

    var value: Data { lock.withLock { data } }
}

/// AppleScript through `osascript`, off the main thread: macOS's "DigUp wants to control Safari" question would
/// otherwise hold the main thread until it's answered.
enum ProductivityAppleScript {
    /// What a run of a script returned.
    struct Reply: Sendable {
        /// What the script returned, trimmed; nil when it failed.
        var value: String?
        /// AppleScript's error number: -1743 not allowed to control the app, -1712 the question wasn't answered in
        /// time, -600 the app isn't running.
        var errorNumber: Int?
        var message: String
    }

    static let notAllowed = -1743

    static func run(_ source: String, arguments: [String] = [], timeout: TimeInterval = 15) async -> Reply {
        let run = await ProductivityProcess.run(URL(fileURLWithPath: "/usr/bin/osascript"),
                                                arguments: ["-e", source] + arguments, timeout: timeout)
        if run.succeeded {
            return Reply(value: run.output.trimmingCharacters(in: .whitespacesAndNewlines), errorNumber: nil,
                         message: "")
        }
        let message = (run.failure ?? run.errors).trimmingCharacters(in: .whitespacesAndNewlines)
        return Reply(value: nil, errorNumber: errorNumber(in: message), message: run.timedOut ? "timed out" : message)
    }

    /// "execution error: Not authorized to send Apple events to Safari. (-1743)" → -1743.
    static func errorNumber(in message: String) -> Int? {
        guard message.hasSuffix(")"), let open = message.lastIndex(of: "(") else { return nil }
        return Int(message[message.index(after: open)..<message.index(before: message.endIndex)])
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}

/// Opening text files to edit them.
enum ProductivityEditor {
    /// Terminals run a script they're asked to open, so they never get one to edit.
    private static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                                                 "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
                                                 "io.alacritty", "co.zeit.hyper"]

    /// In the app that opens its kind of file, unless that's a terminal: then the default text editor, else TextEdit.
    static func open(_ url: URL) {
        let workspace = NSWorkspace.shared
        var app = workspace.urlForApplication(toOpen: url)
        if let found = app, let id = Bundle(url: found)?.bundleIdentifier, terminals.contains(id) { app = nil }
        if app == nil, let editor = workspace.urlForApplication(toOpen: .plainText),
           !terminals.contains(Bundle(url: editor)?.bundleIdentifier ?? "") {
            app = editor
        }
        let editor = app ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        guard let editor else {
            workspace.activateFileViewerSelecting([url])
            return
        }
        workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}

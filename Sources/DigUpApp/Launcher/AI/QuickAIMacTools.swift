import AppKit
import DigUpKit
import Foundation

/// One Mac action Quick AI took (or asked to take) during a turn, shown in the chat.
@Observable
final class QuickAIToolStep: Identifiable {
    enum Status: Equatable {
        case running
        case done
        case failed
        case denied
    }

    let id = UUID()
    let name: String
    let title: String
    /// Short line under the title (path, command preview, or "exit 0 · 12 lines").
    var detail: String
    /// Live or full tool output for the expandable panel (shell stdout); empty for simple file tools.
    var output: String = ""
    /// Images loaded by `look_at_image` for the next model round (vision).
    var visionImages: [AIImageAttachment] = []
    var status: Status
    /// User expanded this step to read the full output.
    var expanded = false

    init(name: String, title: String, detail: String, status: Status = .running) {
        self.name = name
        self.title = title
        self.detail = detail
        self.status = status
    }

    /// One-line summary for a cancelled turn that never got a prose answer.
    var lineSummary: String {
        let tail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty { return title }
        return "\(title): \(tail)"
    }
}

/// Runs DigUp's Mac tools for Quick AI: files (list / trash / move / reveal / open) and shell commands.
enum QuickAIMacTools {
    static let maxShellSeconds: TimeInterval = 30
    static let maxOutputCharacters = 8_000

    /// Builds a running step so the chat can show it before the tool finishes.
    static func makeStep(for call: AIToolCall) -> QuickAIToolStep {
        let args = AIJSONValue.parseObject(call.arguments) ?? [:]
        return QuickAIToolStep(name: call.name, title: displayTitle(for: call.name),
                               detail: preview(for: call.name, args: args), status: .running)
    }

    /// Executes one model tool call into `step`, streaming shell output via `onUpdate`. Trash and delete-like
    /// shell ask first. Returns the full result string for the model (not the short UI detail).
    static func run(_ call: AIToolCall, step: QuickAIToolStep, context: LauncherContext?,
                    onUpdate: @escaping @MainActor () -> Void) async -> String {
        let args = AIJSONValue.parseObject(call.arguments) ?? [:]
        let preview = step.detail

        do {
            let result: String
            switch call.name {
            case AIMacToolCatalog.listDirectory:
                result = try listDirectory(args: args)
                step.detail = shortPathResult(result)
            case AIMacToolCatalog.trashPath:
                guard await confirm("Move to Trash?", message: preview, button: "Move to Trash",
                                    destructive: true, context: context) else {
                    return deny(step, "You cancelled moving that to the Trash.")
                }
                result = try trash(args: args)
                step.detail = result
            case AIMacToolCatalog.movePath:
                result = try move(args: args)
                step.detail = result
            case AIMacToolCatalog.revealPath:
                result = try reveal(args: args)
                step.detail = result
            case AIMacToolCatalog.openPath:
                result = try open(args: args)
                step.detail = result
            case AIMacToolCatalog.lookAtImage:
                result = try lookAtImage(args: args, step: step)
            case AIMacToolCatalog.lookAtScreen:
                result = try await lookAtScreen(step: step, context: context)
            case AIMacToolCatalog.runShell:
                let command = args["command"]?.string ?? preview
                if AIMacShellRisk.canDeleteFiles(command) {
                    guard await confirm("Run this command?", message: preview, button: "Run",
                                        destructive: true, context: context) else {
                        return deny(step, "You cancelled the shell command.")
                    }
                }
                guard !Task.isCancelled else { return deny(step, "Stopped before the command ran.") }
                result = try await shell(args: args, step: step, onUpdate: onUpdate)
            default:
                throw ToolError("Unknown tool “\(call.name)”.")
            }
            step.status = .done
            await MainActor.run(body: onUpdate)
            return result
        } catch is CancellationError {
            return deny(step, "Stopped.")
        } catch {
            let message = (error as? ToolError)?.message ?? error.localizedDescription
            step.detail = message
            step.status = .failed
            await MainActor.run(body: onUpdate)
            return "Error: \(message)"
        }
    }

    // MARK: Tools

    private static func listDirectory(args: [String: AIJSONValue]) throws -> String {
        let url = try pathURL(args["path"]?.string, label: "path")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolError("Nothing exists at \(tilde(url.path)).")
        }
        guard isDirectory.boolValue else {
            throw ToolError("\(tilde(url.path)) is a file, not a folder.")
        }
        let items = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        if items.isEmpty { return "\(tilde(url.path)) is empty." }
        let lines = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { item -> String in
                let dir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return (dir ? "📁 " : "📄 ") + item.lastPathComponent
            }
        return "Contents of \(tilde(url.path)) (\(lines.count)):\n" + lines.joined(separator: "\n")
    }

    private static func trash(args: [String: AIJSONValue]) throws -> String {
        let url = try pathURL(args["path"]?.string, label: "path")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("Nothing exists at \(tilde(url.path)).")
        }
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        let trashed = (resulting as URL?)?.path
        return "Moved \(tilde(url.path)) to the Trash"
            + (trashed.map { " (\(tilde($0)))." } ?? ".")
    }

    private static func move(args: [String: AIJSONValue]) throws -> String {
        let from = try pathURL(args["from"]?.string, label: "from")
        let to = try pathURL(args["to"]?.string, label: "to")
        guard FileManager.default.fileExists(atPath: from.path) else {
            throw ToolError("Nothing exists at \(tilde(from.path)).")
        }
        let parent = to.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try FileManager.default.moveItem(at: from, to: to)
        return "Moved \(tilde(from.path)) → \(tilde(to.path))."
    }

    private static func reveal(args: [String: AIJSONValue]) throws -> String {
        let url = try pathURL(args["path"]?.string, label: "path")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("Nothing exists at \(tilde(url.path)).")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return "Revealed \(tilde(url.path)) in Finder."
    }

    private static func open(args: [String: AIJSONValue]) throws -> String {
        let url = try pathURL(args["path"]?.string, label: "path")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("Nothing exists at \(tilde(url.path)).")
        }
        // Don't activate the other app: that resigns DigUp, hides the panel, and used to cancel the answer.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
        return "Opened \(tilde(url.path))."
    }

    /// Loads a local image into `step.visionImages` so the next model round can see it.
    private static func lookAtImage(args: [String: AIJSONValue], step: QuickAIToolStep) throws -> String {
        let url = try pathURL(args["path"]?.string, label: "path")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("Nothing exists at \(tilde(url.path)).")
        }
        guard let pending = QuickAIImages.fromFile(url) else {
            throw ToolError("Couldn't read \(tilde(url.path)) as an image (unsupported type or too large).")
        }
        step.visionImages = [pending.attachment]
        step.detail = tilde(url.path)
        return "Attached \(tilde(url.path)) for you to see. Describe what is in the image."
    }

    /// Fresh display capture for desktop / widget / "what's on screen" questions (not an old Desktop PNG).
    private static func lookAtScreen(step: QuickAIToolStep, context: LauncherContext?) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("digup-screen-\(UUID().uuidString).png", isDirectory: false)
        let wasVisible = await MainActor.run { context?.isPanelVisible ?? false }
        if wasVisible {
            await MainActor.run { context?.hide() }
            try await Task.sleep(for: .milliseconds(180))
        }
        defer {
            if wasVisible {
                Task { @MainActor in context?.show() }
            }
            try? FileManager.default.removeItem(at: url)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ToolError("Couldn't run screencapture (\(error.localizedDescription)).")
        }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError(
                "Screen capture failed. Allow DigUp under System Settings → Privacy & Security → Screen Recording, then try again.")
        }
        guard let pending = QuickAIImages.fromFile(url) else {
            throw ToolError("Captured the screen but couldn't read the image.")
        }
        step.visionImages = [pending.attachment]
        step.detail = "Display"
        return "Attached a fresh screenshot of the display. Describe what is on screen (desktop, widgets, windows)."
    }

    /// Runs the shell command, streaming stdout/stderr into `step.output` as bytes arrive.
    private static func shell(args: [String: AIJSONValue], step: QuickAIToolStep,
                              onUpdate: @escaping @MainActor () -> Void) async throws -> String {
        guard let command = args["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            throw ToolError("Missing “command”.")
        }
        let cwd = AIMacToolCatalog.resolvePath(args["working_directory"]?.string ?? "~")
            ?? NSHomeDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.environment = ProcessInfo.processInfo.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let limit = maxOutputCharacters
        let push: @Sendable (String) -> Void = { chunk in
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                var next = step.output + chunk
                if next.count > limit { next = String(next.suffix(limit)) }
                step.output = next
                step.detail = ""
                onUpdate()
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            push(text)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            push(text)
        }

        try process.run()
        let deadline = Date().addingTimeInterval(maxShellSeconds)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled {
                process.terminate()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                throw CancellationError()
            }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            throw ToolError("The command ran over \(Int(maxShellSeconds)) seconds and was stopped.")
        }
        if let rest = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            push(rest)
        }
        if let rest = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            push(rest)
        }
        try? await Task.sleep(for: .milliseconds(30))

        let status = process.terminationStatus
        return await MainActor.run {
            let body = step.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = body.isEmpty ? "(no output)" : body
            step.output = shown
            // Keep the row title-only (Claude-style); exit/line counts stay in the expandable output.
            step.detail = ""
            onUpdate()
            return truncate("exit \(status)\n\(shown)")
        }
    }

    // MARK: Helpers

    private static func pathURL(_ raw: String?, label: String) throws -> URL {
        guard let raw, let resolved = AIMacToolCatalog.resolvePath(raw) else {
            throw ToolError("Missing “\(label)”.")
        }
        return URL(fileURLWithPath: resolved)
    }

    private static func confirm(_ title: String, message: String, button: String, destructive: Bool,
                                context: LauncherContext?) async -> Bool {
        guard let context else { return false }
        return await MainActor.run {
            context.confirm(title, message: message, button: button, destructive: destructive)
        }
    }

    private static func deny(_ step: QuickAIToolStep, _ message: String) -> String {
        step.status = .denied
        step.detail = message
        step.output = ""
        return message
    }

    private static func shortPathResult(_ result: String) -> String {
        if let count = result.split(separator: "\n").first,
           count.contains("("), count.hasSuffix("):") || count.contains("):") {
            // "Contents of ~/Desktop (12):"
            if let open = count.lastIndex(of: "("), let close = count.lastIndex(of: ")") {
                return String(count[count.index(after: open)..<close]) + " items"
            }
        }
        if result.hasSuffix("is empty.") { return "empty" }
        return String(result.prefix(80))
    }

    private static func displayTitle(for name: String) -> String {
        switch name {
        case AIMacToolCatalog.listDirectory: "List folder"
        case AIMacToolCatalog.trashPath: "Move to Trash"
        case AIMacToolCatalog.movePath: "Move"
        case AIMacToolCatalog.revealPath: "Reveal in Finder"
        case AIMacToolCatalog.openPath: "Open"
        case AIMacToolCatalog.lookAtImage: "Look at image"
        case AIMacToolCatalog.lookAtScreen: "Look at screen"
        case AIMacToolCatalog.runShell: "Run shell"
        default: name
        }
    }

    private static func preview(for name: String, args: [String: AIJSONValue]) -> String {
        switch name {
        case AIMacToolCatalog.listDirectory, AIMacToolCatalog.trashPath,
             AIMacToolCatalog.revealPath, AIMacToolCatalog.openPath, AIMacToolCatalog.lookAtImage:
            return tilde(AIMacToolCatalog.resolvePath(args["path"]?.string ?? "") ?? args["path"]?.string ?? "")
        case AIMacToolCatalog.lookAtScreen:
            return "Display"
        case AIMacToolCatalog.movePath:
            let from = tilde(AIMacToolCatalog.resolvePath(args["from"]?.string ?? "") ?? args["from"]?.string ?? "")
            let to = tilde(AIMacToolCatalog.resolvePath(args["to"]?.string ?? "") ?? args["to"]?.string ?? "")
            return "\(from) → \(to)"
        case AIMacToolCatalog.runShell:
            return ""
        default:
            return ""
        }
    }

    private static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maxOutputCharacters else { return text }
        return String(text.prefix(maxOutputCharacters)) + "\n… (truncated)"
    }

    private struct ToolError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }
}

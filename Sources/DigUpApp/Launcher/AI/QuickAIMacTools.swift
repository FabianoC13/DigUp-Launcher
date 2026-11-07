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
    var detail: String
    var status: Status

    init(name: String, title: String, detail: String, status: Status = .running) {
        self.name = name
        self.title = title
        self.detail = detail
        self.status = status
    }
}

/// Runs DigUp's Mac tools for Quick AI: files (list / trash / move / reveal / open) and shell commands.
enum QuickAIMacTools {
    static let maxShellSeconds: TimeInterval = 30
    static let maxOutputCharacters = 8_000

    /// Executes one model tool call. Trash and shell commands that can delete files ask first; everything else runs.
    static func run(_ call: AIToolCall, context: LauncherContext?) async -> (result: String, step: QuickAIToolStep) {
        let args = AIJSONValue.parseObject(call.arguments) ?? [:]
        let title = displayTitle(for: call.name)
        let preview = preview(for: call.name, args: args)
        let step = QuickAIToolStep(name: call.name, title: title, detail: preview, status: .running)

        do {
            let result: String
            switch call.name {
            case AIMacToolCatalog.listDirectory:
                result = try listDirectory(args: args)
            case AIMacToolCatalog.trashPath:
                guard await confirm("Move to Trash?", message: preview, button: "Move to Trash",
                                    destructive: true, context: context) else {
                    return denied(step, "You cancelled moving that to the Trash.")
                }
                result = try trash(args: args)
            case AIMacToolCatalog.movePath:
                result = try move(args: args)
            case AIMacToolCatalog.revealPath:
                result = try reveal(args: args)
            case AIMacToolCatalog.openPath:
                result = try open(args: args)
            case AIMacToolCatalog.runShell:
                let command = args["command"]?.string ?? preview
                if AIMacShellRisk.canDeleteFiles(command) {
                    guard await confirm("Run this command?", message: preview, button: "Run",
                                        destructive: true, context: context) else {
                        return denied(step, "You cancelled the shell command.")
                    }
                }
                // Panel auto-hide during the alert used to cancel this task; bail cleanly if that still happens.
                guard !Task.isCancelled else { return denied(step, "Stopped before the command ran.") }
                result = try await shell(args: args)
            default:
                throw ToolError("Unknown tool “\(call.name)”.")
            }
            step.detail = truncate(result)
            step.status = .done
            return (result, step)
        } catch is CancellationError {
            return denied(step, "Stopped.")
        } catch {
            let message = (error as? ToolError)?.message ?? error.localizedDescription
            step.detail = message
            step.status = .failed
            return ("Error: \(message)", step)
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
        NSWorkspace.shared.open(url)
        return "Opened \(tilde(url.path))."
    }

    private static func shell(args: [String: AIJSONValue]) async throws -> String {
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

        try process.run()
        let deadline = Date().addingTimeInterval(maxShellSeconds)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
        }
        if process.isRunning {
            process.terminate()
            throw ToolError("The command ran over \(Int(maxShellSeconds)) seconds and was stopped.")
        }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var parts: [String] = []
        if !out.isEmpty { parts.append(out.trimmingCharacters(in: .newlines)) }
        if !err.isEmpty { parts.append("stderr:\n" + err.trimmingCharacters(in: .newlines)) }
        let body = parts.isEmpty ? "(no output)" : parts.joined(separator: "\n")
        let status = process.terminationStatus
        return truncate("exit \(status)\n\(body)")
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

    private static func denied(_ step: QuickAIToolStep, _ message: String) -> (String, QuickAIToolStep) {
        step.status = .denied
        step.detail = message
        return (message, step)
    }

    private static func displayTitle(for name: String) -> String {
        switch name {
        case AIMacToolCatalog.listDirectory: "List folder"
        case AIMacToolCatalog.trashPath: "Move to Trash"
        case AIMacToolCatalog.movePath: "Move"
        case AIMacToolCatalog.revealPath: "Reveal in Finder"
        case AIMacToolCatalog.openPath: "Open"
        case AIMacToolCatalog.runShell: "Run shell"
        default: name
        }
    }

    private static func preview(for name: String, args: [String: AIJSONValue]) -> String {
        switch name {
        case AIMacToolCatalog.listDirectory, AIMacToolCatalog.trashPath,
             AIMacToolCatalog.revealPath, AIMacToolCatalog.openPath:
            return tilde(AIMacToolCatalog.resolvePath(args["path"]?.string ?? "") ?? args["path"]?.string ?? "")
        case AIMacToolCatalog.movePath:
            let from = tilde(AIMacToolCatalog.resolvePath(args["from"]?.string ?? "") ?? args["from"]?.string ?? "")
            let to = tilde(AIMacToolCatalog.resolvePath(args["to"]?.string ?? "") ?? args["to"]?.string ?? "")
            return "\(from) → \(to)"
        case AIMacToolCatalog.runShell:
            return args["command"]?.string ?? ""
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

import AppKit
import DigUpKit
import Observation
import SwiftUI

/// Running script commands: their arguments (typed after the title, or asked for), confirmation, the process, and its
/// output by mode (fullOutput shown in full, compact and inline the last line in the footer, silent the last line in a
/// HUD once the panel has closed).
enum ScriptsRunner {
    /// Scripts that run longer are stopped.
    static let timeout: TimeInterval = 60

    /// Whether a run asks for arguments first (so the panel stays up for it).
    static func needsArgumentMode(_ script: ScriptCommand, typed: String) -> Bool {
        let arguments = script.metadata.arguments
        guard !arguments.isEmpty else { return false }
        if arguments.contains(where: { $0.kind == .password }) { return true }
        return resolve(arguments, typed: typed).missing != nil
    }

    /// The typed values, matched to the arguments: dropdowns take an option's title or value. `missing` is the first
    /// argument still to ask for (a required one without a value, or a dropdown value that isn't an option).
    static func resolve(_ arguments: [ScriptArgument], typed: String) -> (values: [String], missing: Int?) {
        let typedValues = ScriptCommandLine.split(typed, count: arguments.count)
        var values: [String] = []
        for (index, argument) in arguments.enumerated() {
            guard index < typedValues.count else {
                if arguments[index...].contains(where: { !$0.optional }) { return (values, index) }
                break
            }
            let value = typedValues[index]
            if argument.kind == .dropdown {
                guard let option = argument.options.first(where: {
                    $0.value.caseInsensitiveCompare(value) == .orderedSame
                        || $0.title.caseInsensitiveCompare(value) == .orderedSame
                }) else { return (values, index) }
                values.append(option.value)
            } else {
                values.append(value)
            }
        }
        return (values, nil)
    }

    /// ↩ on a script: asks for what's missing, then runs it.
    static func start(_ script: ScriptCommand, typed: String, context: LauncherContext) async {
        let arguments = script.metadata.arguments
        if arguments.contains(where: { $0.kind == .password }) {
            // Never typed in the search field, where it would show: every argument is asked for, the password in a
            // secure field.
            context.push(ScriptArgumentsMode(script: script, values: []))
            return
        }
        let (values, missing) = resolve(arguments, typed: typed)
        if missing != nil {
            context.push(ScriptArgumentsMode(script: script, values: values))
            return
        }
        await execute(script, values: values, context: context)
    }

    /// Runs the script with all its argument values, after asking when it wants confirmation.
    static func execute(_ script: ScriptCommand, values: [String], context: LauncherContext) async {
        let metadata = script.metadata
        if metadata.needsConfirmation {
            let shown = values.isEmpty ? "" : "\n\nArguments: " + values.joined(separator: ", ")
            guard context.confirm("Run “\(script.title)”?", message: tildePath(script.url.path) + shown,
                                  button: "Run") else { return }
        }
        switch metadata.mode {
        case .fullOutput:
            let mode = ScriptOutputMode(script: script, values: values)
            context.push(mode)
            mode.run()
        case .compact, .inline:
            if context.isPanelVisible { context.flash("Running “\(script.title)”…") }
            let run = await perform(script, values: values)
            let message = summary(of: run, script: script)
            if metadata.mode == .inline, run.succeeded {
                ScriptsLibrary.shared.inlineOutputs[script.id] = .init(text: message, at: Date())
                if context.isPanelVisible { context.refresh() }
            }
            ProductivityHUD.tell(message, symbol: run.succeeded ? "terminal" : "exclamationmark.triangle",
                                 context: context)
        case .silent:
            if context.isPanelVisible { context.hide() }
            let run = await perform(script, values: values)
            ProductivityHUD.show(summary(of: run, script: script),
                                 symbol: run.succeeded ? "terminal" : "exclamationmark.triangle")
        }
    }

    /// The last line of the output, or what went wrong.
    static func summary(of run: ProductivityRun, script: ScriptCommand) -> String {
        if let failure = run.failure { return "“\(script.title)” didn't start: \(failure)" }
        if run.timedOut { return "“\(script.title)” ran over \(Int(timeout)) seconds and was stopped" }
        if run.status != 0 {
            let why = ScriptCommandLine.lastLine(run.errors) ?? ScriptCommandLine.lastLine(run.output)
            return "“\(script.title)” failed" + (why.map { ": \($0)" } ?? " (exit status \(run.status))")
        }
        return ScriptCommandLine.lastLine(run.output) ?? "“\(script.title)” finished"
    }

    /// The process: the script itself when executable, else its `#!` interpreter (or its extension's); PATH with
    /// Homebrew's folders; the metadata's working directory, else the script's folder.
    static func perform(_ script: ScriptCommand, values: [String]) async -> ProductivityRun {
        let encoded = zip(script.metadata.arguments, values).map { $0.encode($1) }
        let executable: URL
        var arguments: [String]
        if script.isExecutable {
            executable = script.url
            arguments = encoded
        } else if let interpreter = ScriptCommandLine.interpreter(firstLine: script.firstLine,
                                                                  pathExtension: script.url.pathExtension) {
            if interpreter[0].hasPrefix("/") {
                executable = URL(fileURLWithPath: interpreter[0])
                arguments = Array(interpreter.dropFirst())
            } else {
                executable = URL(fileURLWithPath: "/usr/bin/env")
                arguments = interpreter
            }
            arguments += [script.url.path] + encoded
        } else {
            var run = ProductivityRun()
            run.failure = "it isn't executable and has no #! line (chmod +x \(script.url.lastPathComponent))"
            return run
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ScriptCommandLine.searchPath(existing: environment["PATH"])
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        let folder = script.url.deletingLastPathComponent()
        var directory = folder
        if let path = script.metadata.currentDirectoryPath {
            let expanded = (path as NSString).expandingTildeInPath
            directory = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true)
                : folder.appendingPathComponent(expanded, isDirectory: true)
        }
        var isFolder: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isFolder) || !isFolder.boolValue {
            directory = folder
        }
        log("scripts: running \(script.url.lastPathComponent) (\(values.count) arguments)")
        let run = await ProductivityProcess.run(executable, arguments: arguments, environment: environment,
                                                directory: directory, timeout: timeout)
        log("scripts: \(script.url.lastPathComponent) " + (run.failure.map { "didn't start: \($0)" }
            ?? (run.timedOut ? "timed out" : "exited \(run.status) in \(String(format: "%.1f", run.duration)) s")))
        return run
    }

    /// One line of secret text, typed into a secure field; nil when cancelled.
    static func askSecret(_ title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        bringAppToFront()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

/// Asks for a script's arguments one at a time: what's typed is the value (a dropdown lists its options), ↩ goes on to
/// the next, and the last runs the script.
@Observable
final class ScriptArgumentsMode: LauncherMode {
    let script: ScriptCommand
    private(set) var values: [String]

    init(script: ScriptCommand, values: [String]) {
        self.script = script
        self.values = values
    }

    private var arguments: [ScriptArgument] { script.metadata.arguments }
    private var current: ScriptArgument? { values.count < arguments.count ? arguments[values.count] : nil }

    var title: String { script.title }
    var icon: LauncherIcon { ScriptsLibrary.shared.icon(for: script) }
    var placeholder: String {
        guard let current else { return "" }
        return current.placeholder + (current.optional ? " (optional)" : "")
    }
    var statusHint: String? { "Argument \(min(values.count + 1, arguments.count)) of \(arguments.count)" }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard let current else { return [] }
        let isLast = values.count == arguments.count - 1
        let next = isLast ? "Run “\(script.title)”" : "Next: \(arguments[values.count + 1].placeholder)"
        let given = zip(arguments, values).map { "\($0.placeholder): \($1.isEmpty ? "—" : $1)" }
        switch current.kind {
        case .dropdown:
            return current.options.compactMap { option in
                guard query.isEmpty || query.match(option.title, keywords: [option.value]) != nil else { return nil }
                return LauncherItem(id: "script-arg:\(option.value)", title: option.title,
                                    subtitle: given.isEmpty ? next : given.joined(separator: " · "),
                                    icon: .symbol("list.bullet"), section: .named(current.placeholder, order: 0),
                                    actions: [commit(option.value, title: isLast ? "Run" : "Choose")],
                                    tracksUsage: false)
            }
        case .password:
            return [LauncherItem(id: "script-arg:secret", title: "Enter \(current.placeholder)…",
                                 subtitle: "Typed in a secure field, never shown", icon: .symbol("key"),
                                 actions: [LauncherAction(id: "secret", title: "Enter", symbol: "key",
                                                          keepsPanelOpen: true) { [weak self] context in
                                     guard let self else { return }
                                     guard let secret = ScriptsRunner.askSecret(current.placeholder,
                                                                                message: "For “\(self.script.title)”")
                                     else { return }
                                     await self.accept(secret, context: context)
                                 }],
                                 tracksUsage: false)]
        case .text:
            let value = query.text
            let subtitle = value.isEmpty && !current.optional
                ? "Type the \(current.placeholder.lowercased()) first"
                : (given + [current.placeholder + ": " + (value.isEmpty ? "—" : value)]).joined(separator: " · ")
            return [LauncherItem(id: "script-arg:text", title: next, subtitle: subtitle,
                                 icon: isLast ? .symbol("play") : .symbol("arrow.right"),
                                 actions: [commit(value, title: isLast ? "Run" : "Next")], tracksUsage: false)]
        }
    }

    private func commit(_ value: String, title: String) -> LauncherAction {
        LauncherAction(id: "commit", title: title, symbol: "return", keepsPanelOpen: true) { [weak self] context in
            await self?.accept(value, context: context)
        }
    }

    /// One more value: on to the next argument, or run.
    private func accept(_ value: String, context: LauncherContext) async {
        guard let current else { return }
        if value.isEmpty, !current.optional {
            context.flash("\(current.placeholder) is needed")
            return
        }
        values.append(value)
        if values.count < arguments.count {
            context.query = ""
            context.refresh()
            return
        }
        let values = self.values
        let script = self.script
        context.popToRoot()
        await ScriptsRunner.execute(script, values: values, context: context)
    }
}

/// A fullOutput script's run: its output in full, monospaced, as it finishes. ↩ copies it, ⌘R runs it again; what's
/// typed keeps only the lines with it.
@Observable
final class ScriptOutputMode: LauncherMode {
    let script: ScriptCommand
    let values: [String]
    private(set) var result: ProductivityRun?
    private(set) var running = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// What's typed, to filter the lines.
    var filter = ""

    init(script: ScriptCommand, values: [String]) {
        self.script = script
        self.values = values
    }

    var title: String { script.title }
    var placeholder: String { "Filter the output…" }
    var icon: LauncherIcon { ScriptsLibrary.shared.icon(for: script) }
    var keysHint: String? { "↩ Copy Output   ⌘R Run Again   ⌘E Edit Script   Esc Back" }
    var statusHint: String? {
        guard let result, !running else { return "Running…" }
        if result.failure != nil { return "Didn't start" }
        if result.timedOut { return "Stopped after \(Int(ScriptsRunner.timeout)) s" }
        let time = String(format: "%.1f s", result.duration)
        return result.status == 0 ? "Finished in \(time)" : "Exit status \(result.status) after \(time)"
    }

    /// Output and errors, without terminal colors.
    var text: String {
        guard let result else { return "" }
        if let failure = result.failure { return "The script didn't start: \(failure)" }
        var text = ScriptCommandLine.stripANSI(result.output)
        let errors = ScriptCommandLine.stripANSI(result.errors).trimmingCharacters(in: .whitespacesAndNewlines)
        if !errors.isEmpty { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + errors }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = "(no output)" }
        return text
    }

    func run() {
        task?.cancel()
        running = true
        let script = self.script, values = self.values
        task = Task {
            let run = await ScriptsRunner.perform(script, values: values)
            guard !Task.isCancelled else { return }
            result = run
            running = false
        }
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        filter = query.text
        return []
    }

    func makeView(context: LauncherContext) -> AnyView? {
        AnyView(ScriptOutputView(mode: self))
    }

    func handle(_ event: NSEvent, query: String, context: LauncherContext) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty {
            guard !running else { return true }
            context.copy(text, flash: "Output copied")
            return true
        }
        guard modifiers == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            run()
            return true
        case "e":
            ProductivityEditor.open(script.url)
            return true
        default:
            return false
        }
    }

    func didClose() {
        task?.cancel()
    }
}

private struct ScriptOutputView: View {
    let mode: ScriptOutputMode

    var body: some View {
        Group {
            if mode.running || mode.result == nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Running “\(mode.script.title)”…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(shown)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
    }

    /// The lines with what's typed, or all of them.
    private var shown: String {
        let filter = mode.filter
        guard !filter.isEmpty else { return mode.text }
        let lines = mode.text.components(separatedBy: "\n").filter {
            $0.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return lines.isEmpty ? "No lines with “\(filter)”" : lines.joined(separator: "\n")
    }
}

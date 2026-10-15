import AppKit
import Carbon.HIToolbox
import DigUpKit

// How the system commands reach the system: command-line tools, AppleScript, Apple events to loginwindow and the few
// private calls with no public equivalent. Everything here that can take a while runs off the main thread.
extension SystemFeature {
    /// What a command-line tool printed and how it ended.
    nonisolated struct ToolResult: Sendable {
        var status: Int32
        var output: String
        var error: String
        var succeeded: Bool { status == 0 }
    }

    /// Runs a tool (`/usr/bin/pmset`, `/usr/bin/osascript`…) off the main thread and waits for it to end; it's
    /// stopped after `timeout` seconds.
    nonisolated static func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) async -> ToolResult {
        await Task.detached(priority: .userInitiated) {
            runToolBlocking(path, arguments, timeout: timeout)
        }.value
    }

    nonisolated private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    nonisolated private static func runToolBlocking(_ path: String, _ arguments: [String],
                                                    timeout: TimeInterval) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ToolResult(status: -1, output: "", error: error.localizedDescription)
        }
        let timer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // stderr is read on its own thread, so that neither pipe can fill up and stall the tool.
        let errorBox = DataBox()
        let errorRead = DispatchGroup()
        errorRead.enter()
        DispatchQueue.global().async {
            errorBox.data = error.fileHandleForReading.readDataToEndOfFile()
            errorRead.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        errorRead.wait()
        process.waitUntilExit()
        timer.cancel()
        return ToolResult(status: process.terminationStatus,
                          output: String(decoding: outputData, as: UTF8.self),
                          error: String(decoding: errorBox.data, as: UTF8.self))
    }

    // MARK: AppleScript

    /// An AppleScript's result, or why it failed.
    nonisolated struct ScriptResult: Sendable {
        var output: String
        /// The AppleScript error number, when it failed (-1743: not allowed in Privacy & Security → Automation).
        var errorCode: Int?
        var errorText: String
        var succeeded: Bool
    }

    /// Runs AppleScript in `osascript` (one line per element), off the main thread. A script that sends Apple events to
    /// an app (System Events, Finder) makes macOS ask once whether DigUp may control it.
    nonisolated static func appleScript(_ lines: [String], timeout: TimeInterval = 30) async -> ScriptResult {
        let arguments = lines.flatMap { ["-e", $0] }
        let result = await runTool("/usr/bin/osascript", arguments, timeout: timeout)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScriptResult(output: output, errorCode: result.succeeded ? nil : LauncherSystemOutput.scriptErrorCode(error),
                            errorText: error, succeeded: result.succeeded)
    }

    /// Says why an AppleScript to `app` failed, in the panel or the HUD; when macOS refused it (Automation is off for
    /// DigUp), opens the Automation pane where it's turned on.
    static func reportScriptFailure(_ result: ScriptResult, app: String, doing what: String, context: LauncherContext) {
        log("system: \(what) failed: \(result.errorCode.map(String.init) ?? "no code") \(result.errorText.prefix(200))")
        switch result.errorCode {
        case LauncherSystemOutput.notAuthorized:
            SystemHUD.report("Allow DigUp to control \(app) in Privacy & Security → Automation",
                             symbol: "lock.shield", context: context)
            openAutomationSettings()
        case LauncherSystemOutput.timedOut:
            SystemHUD.report("\(app) didn't answer in time", symbol: "exclamationmark.triangle", context: context)
        case LauncherSystemOutput.userCancelled:
            break
        default:
            SystemHUD.report("Couldn't \(what)", symbol: "exclamationmark.triangle", context: context)
        }
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    // MARK: loginwindow

    /// Restart, shut down or log out: the Apple event loginwindow takes for it (Technical Q&A QA1134). Apps are asked
    /// to quit first, and any of them can still stop it (a document that isn't saved). Nil when sent, else the error.
    nonisolated static func sendToLoginWindow(_ eventID: AEEventID) async -> Int? {
        await Task.detached(priority: .userInitiated) { () -> Int? in
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
            let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass),
                                                          eventID: eventID,
                                                          targetDescriptor: target,
                                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                                          transactionID: AETransactionID(kAnyTransactionID))
            do {
                _ = try event.sendEvent(options: [.noReply], timeout: 30)
                return nil
            } catch {
                return (error as NSError).code
            }
        }.value
    }

    // MARK: Private calls

    /// A C function from a system framework that has no public equivalent, looked up at run time so that DigUp keeps
    /// working (with its fallback) if a macOS update removes it.
    nonisolated static func privateSymbol(_ name: String, in library: String? = nil) -> UnsafeMutableRawPointer? {
        let handle = library.flatMap { dlopen($0, RTLD_LAZY) } ?? UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return dlsym(handle, name)
    }

    /// The Dock's own notifications ("com.apple.showdesktop.awake", "com.apple.expose.awake"): what the Mission
    /// Control keys send. False when the call isn't there.
    static func sendDockNotification(_ name: String) -> Bool {
        typealias Send = @convention(c) (CFString, Int32) -> Void
        guard let symbol = privateSymbol("CoreDockSendNotification",
                                         in: "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
        else { return false }
        unsafeBitCast(symbol, to: Send.self)(name as CFString, 0)
        return true
    }

    /// Locks the screen the way the menu bar's Lock Screen does. False when the call isn't there.
    static func lockScreenNow() -> Bool {
        typealias Lock = @convention(c) () -> Int32
        guard let symbol = privateSymbol("SACLockScreenImmediate",
                                         in: "/System/Library/PrivateFrameworks/login.framework/login")
        else { return false }
        _ = unsafeBitCast(symbol, to: Lock.self)()
        return true
    }

    // MARK: Keys

    /// A media key (play/pause, next, previous) as the keyboard sends it: macOS gives it to whatever is playing.
    /// Posting it needs Accessibility.
    static func postMediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// ⌃⌘Q, the system's lock shortcut (when the private call is gone). Needs Accessibility.
    static func postLockShortcut() {
        Keystrokes.post(keyCode: CGKeyCode(kVK_ANSI_Q), flags: [.maskControl, .maskCommand])
    }
}

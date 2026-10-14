import AppKit
import DigUpKit

// What each system command does. They run after the panel has hidden, so they speak through `SystemHUD.report`.
extension SystemFeature {
    // MARK: Power and session

    static func lockScreen(_ context: LauncherContext) {
        if lockScreenNow() { return }
        // The private call is gone: the system's ⌃⌘Q, which needs Accessibility to post.
        log("system: SACLockScreenImmediate isn't there; posting ⌃⌘Q")
        guard Accessibility.isTrusted(prompt: true) else {
            SystemHUD.report("Allow DigUp in Privacy & Security → Accessibility to lock the screen",
                             symbol: "lock.shield", context: context)
            return
        }
        postLockShortcut()
    }

    static func sleepNow(_ context: LauncherContext) async {
        let result = await runTool("/usr/bin/pmset", ["sleepnow"])
        if !result.succeeded {
            log("system: pmset sleepnow failed: \(result.error.prefix(200))")
            SystemHUD.report("Couldn't put the Mac to sleep", symbol: "exclamationmark.triangle", context: context)
        }
    }

    static func sleepDisplays(_ context: LauncherContext) async {
        let result = await runTool("/usr/bin/pmset", ["displaysleepnow"])
        if !result.succeeded {
            log("system: pmset displaysleepnow failed: \(result.error.prefix(200))")
            SystemHUD.report("Couldn't turn the displays off", symbol: "exclamationmark.triangle", context: context)
        }
    }

    enum SessionEnd {
        case restart, shutDown, logOut

        /// loginwindow's Apple event (AERegistry.h): it doesn't ask again.
        var eventID: AEEventID {
            switch self {
            case .restart: AEEventID(kAERestart)
            case .shutDown: AEEventID(kAEShutDown)
            case .logOut: AEEventID(kAEReallyLogOut)
            }
        }

        /// The same through System Events, when loginwindow won't take the event.
        var systemEventsCommand: String {
            switch self {
            case .restart: "restart"
            case .shutDown: "shut down"
            case .logOut: "log out"
            }
        }

        var question: String {
            switch self {
            case .restart: "Restart the Mac now?"
            case .shutDown: "Shut down the Mac now?"
            case .logOut: "Log out now?"
            }
        }

        var button: String {
            switch self {
            case .restart: "Restart"
            case .shutDown: "Shut Down"
            case .logOut: "Log Out"
            }
        }
    }

    /// Restart, shut down or log out, once you've said yes.
    static func endSession(_ kind: SessionEnd, _ context: LauncherContext) async {
        guard context.confirm(kind.question,
                              message: "Open apps are asked to quit first. One with unsaved changes can still stop it.",
                              button: kind.button) else { return }
        guard let error = await sendToLoginWindow(kind.eventID) else { return }
        log("system: loginwindow refused \(kind.button) (\(error)); asking System Events")
        let result = await appleScript(["tell application \"System Events\" to \(kind.systemEventsCommand)"])
        if !result.succeeded {
            reportScriptFailure(result, app: "System Events", doing: kind.button.lowercased(), context: context)
        }
    }

    static func startScreenSaver(_ context: LauncherContext) async {
        await openApp(at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"), context)
    }

    // MARK: Trash

    /// Asks Finder how much is in the Trash (on every disk), says so, and empties it once you've said yes.
    static func emptyTrash(_ context: LauncherContext) async {
        let count = await appleScript(["tell application \"Finder\" to count items of trash"])
        guard count.succeeded, let items = Int(count.output) else {
            reportScriptFailure(count, app: "Finder", doing: "read the Trash", context: context)
            return
        }
        guard items > 0 else {
            SystemHUD.report("The Trash is already empty", symbol: "trash", context: context)
            return
        }
        let what = items == 1 ? "The item in the Trash" : "The \(items) items in the Trash"
        guard context.confirm("Empty the Trash?", message: "\(what) will be deleted for good. This can't be undone.",
                              button: "Empty Trash", destructive: true) else { return }
        let result = await appleScript(["with timeout of 600 seconds",
                                        "tell application \"Finder\" to empty trash",
                                        "end timeout"], timeout: 610)
        if result.succeeded {
            SystemHUD.report(items == 1 ? "Emptied the Trash (1 item)" : "Emptied the Trash (\(items) items)",
                             symbol: "trash.slash", context: context)
        } else {
            reportScriptFailure(result, app: "Finder", doing: "empty the Trash", context: context)
        }
    }

    static func openTrash() {
        let trash = (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil,
                                                  create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        NSWorkspace.shared.open(trash)
    }

    // MARK: Appearance

    /// Dark mode on, off, or (nil) the other way round, through System Events' appearance preferences.
    static func setDarkMode(_ on: Bool?, _ context: LauncherContext) async {
        let value = on.map { $0 ? "true" : "false" } ?? "not dark mode"
        let result = await appleScript([
            "tell application \"System Events\"",
            "tell appearance preferences",
            "set dark mode to \(value)",
            "return dark mode",
            "end tell",
            "end tell",
        ])
        guard result.succeeded else {
            reportScriptFailure(result, app: "System Events", doing: "change the appearance", context: context)
            return
        }
        let dark = result.output == "true"
        SystemHUD.report(dark ? "Dark mode on" : "Light mode on", symbol: dark ? "moon.fill" : "sun.max.fill",
                         context: context)
    }

    // MARK: Sound

    /// The output's volume and mute, from AppleScript's `get volume settings` (no permission needed).
    private static func volumeSettings() async -> LauncherVolumeSettings? {
        let result = await appleScript(["get volume settings"])
        return result.succeeded ? LauncherVolumeSettings(result.output) : nil
    }

    private static func setVolumeNow(_ level: Int, unmute: Bool) async -> Bool {
        var lines = ["set volume output volume \(level)"]
        if unmute { lines.append("set volume output muted false") }
        let result = await appleScript(lines)
        if !result.succeeded { log("system: set volume failed: \(result.errorText.prefix(200))") }
        return result.succeeded
    }

    private static func reportVolume(_ level: Int, _ context: LauncherContext) {
        SystemHUD.report(level == 0 ? "Volume 0%" : "Volume \(level)%", symbol: volumeSymbol(level), context: context)
    }

    private static func reportNoVolumeControl(_ context: LauncherContext) {
        SystemHUD.report("This sound output has no volume control", symbol: "speaker.slash", context: context)
    }

    /// One step (about one volume key's) up or down; going up unmutes, like the keys.
    static func stepVolume(up: Bool, _ context: LauncherContext) async {
        guard let settings = await volumeSettings(), let volume = settings.output else {
            reportNoVolumeControl(context)
            return
        }
        let level = LauncherVolumeSettings.stepped(volume, by: up ? 6 : -6)
        guard await setVolumeNow(level, unmute: up) else {
            reportNoVolumeControl(context)
            return
        }
        reportVolume(level, context)
    }

    static func setVolume(_ level: Int, _ context: LauncherContext) async {
        guard await setVolumeNow(level, unmute: level > 0) else {
            reportNoVolumeControl(context)
            return
        }
        reportVolume(level, context)
    }

    /// Mute, unmute, or (nil) the other way round.
    static func setMuted(_ muted: Bool?, _ context: LauncherContext) async {
        guard let settings = await volumeSettings() else {
            reportNoVolumeControl(context)
            return
        }
        let mute = muted ?? !(settings.muted ?? false)
        let result = await appleScript(["set volume output muted \(mute)"])
        guard result.succeeded else {
            reportNoVolumeControl(context)
            return
        }
        if mute {
            SystemHUD.report("Muted", symbol: "speaker.slash.fill", context: context)
        } else {
            let level = settings.output ?? 50
            SystemHUD.report("Sound on (\(level)%)", symbol: volumeSymbol(level), context: context)
        }
    }

    private static let microphoneLevelKey = "launcherSystemMicrophoneLevel"

    /// The input volume to 0, or back to what it was before.
    static func toggleMicrophone(_ context: LauncherContext) async {
        guard let settings = await volumeSettings(), let input = settings.input else {
            SystemHUD.report("This microphone has no volume control", symbol: "mic.slash", context: context)
            return
        }
        let mute = input > 0
        let saved = AppSettings.defaults.integer(forKey: microphoneLevelKey)
        let level = mute ? 0 : (saved > 0 ? saved : 70)
        let result = await appleScript(["set volume input volume \(level)"])
        guard result.succeeded else {
            SystemHUD.report("Couldn't change the microphone's volume", symbol: "exclamationmark.triangle",
                             context: context)
            return
        }
        if mute { AppSettings.defaults.set(input, forKey: microphoneLevelKey) }
        SystemHUD.report(mute ? "Microphone muted" : "Microphone on (\(level)%)",
                         symbol: mute ? "mic.slash.fill" : "mic.fill", context: context)
    }

    // MARK: Media keys

    enum MediaKey: Int32 {
        // NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT, NX_KEYTYPE_PREVIOUS (IOKit's ev_keymap.h).
        case playPause = 16, next = 17, previous = 18
    }

    static func mediaKey(_ key: MediaKey, _ context: LauncherContext) {
        guard Accessibility.isTrusted(prompt: true) else {
            SystemHUD.report("Allow DigUp in Privacy & Security → Accessibility to control media",
                             symbol: "lock.shield", context: context)
            return
        }
        postMediaKey(key.rawValue)
    }

    // MARK: Disks

    /// A volume Eject All Disks takes.
    private struct Ejectable: Sendable {
        let url: URL
        let name: String
    }

    /// Mounted volumes Finder would offer to eject: removable media, disk images, external disks, network shares.
    nonisolated private static func ejectableVolumes() -> [Ejectable] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsEjectableKey,
                                      .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let name = values.volumeLocalizedName ?? url.lastPathComponent
            let info = LauncherVolumeInfo(name: name, isRoot: values.volumeIsRootFileSystem ?? false,
                                          isEjectable: values.volumeIsEjectable ?? false,
                                          isRemovable: values.volumeIsRemovable ?? false,
                                          isLocal: values.volumeIsLocal, isInternal: values.volumeIsInternal)
            return info.shouldEject ? Ejectable(url: url, name: name) : nil
        }
    }

    static func ejectAll(_ context: LauncherContext) async {
        let volumes = await Task.detached { ejectableVolumes() }.value
        guard !volumes.isEmpty else {
            SystemHUD.report("No disks to eject", symbol: "eject", context: context)
            return
        }
        var ejected: [String] = [], failed: [String] = []
        for volume in volumes {
            // Ejecting a disk takes all its volumes: one that went with an earlier one is done.
            let stillMounted = await Task.detached { ejectableVolumes().contains { $0.url == volume.url } }.value
            guard stillMounted else {
                ejected.append(volume.name)
                continue
            }
            do {
                try await FileManager.default.unmountVolume(at: volume.url,
                                                            options: [.allPartitionsAndEjectDisk, .withoutUI])
                ejected.append(volume.name)
            } catch {
                log("system: couldn't eject \(volume.url.path): \(error.localizedDescription)")
                failed.append(volume.name)
            }
        }
        if failed.isEmpty {
            SystemHUD.report("Ejected \(LauncherSystemOutput.list(ejected))", symbol: "eject.fill", context: context)
        } else {
            let done = ejected.isEmpty ? "" : "Ejected \(LauncherSystemOutput.list(ejected)). "
            SystemHUD.report("\(done)Couldn't eject \(LauncherSystemOutput.list(failed)): in use",
                             symbol: "exclamationmark.triangle", context: context)
        }
    }

    // MARK: Apps

    /// Apps with a Dock icon, without DigUp.
    private static func regularApps() -> [NSRunningApplication] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != own && !$0.isTerminated
        }
    }

    /// Asks every app (but Finder, and the one in front if `keepingFrontmost`) to quit, once you've said yes.
    static func quitApps(keepingFrontmost: Bool, _ context: LauncherContext) {
        let front = keepingFrontmost ? context.previousApp : nil
        let apps = regularApps().filter {
            $0.bundleIdentifier != "com.apple.finder" && $0.processIdentifier != front?.processIdentifier
        }
        guard !apps.isEmpty else {
            SystemHUD.report(keepingFrontmost ? "No other apps are open" : "No apps are open", symbol: "checkmark",
                             context: context)
            return
        }
        let names = apps.map { $0.localizedName ?? $0.bundleIdentifier ?? "An app" }
        let title = front.flatMap(\.localizedName).map { "Quit every app except \($0)?" } ?? "Quit every app?"
        let count = apps.count == 1 ? "1 App" : "\(apps.count) Apps"
        guard context.confirm(title,
                              message: "\(LauncherSystemOutput.list(names, limit: 8)) will be asked to quit. "
                                  + "Apps with unsaved changes ask you first.",
                              button: "Quit \(count)", destructive: true) else { return }
        for app in apps { app.terminate() }
        log("system: asked \(apps.count) apps to quit")
        SystemHUD.report("Asked \(count.lowercased()) to quit", symbol: "xmark.circle", context: context)
    }

    static func hideApps(keepingFrontmost: Bool, _ context: LauncherContext) {
        let keep = keepingFrontmost ? context.previousApp?.processIdentifier : nil
        let apps = regularApps().filter { !$0.isHidden && $0.processIdentifier != keep }
        for app in apps { app.hide() }
        if apps.isEmpty {
            SystemHUD.report("No apps to hide", symbol: "eye.slash", context: context)
        }
    }

    static func unhideApps(_ context: LauncherContext) {
        let hidden = regularApps().filter(\.isHidden)
        for app in hidden { app.unhide() }
        if hidden.isEmpty {
            SystemHUD.report("No app is hidden", symbol: "eye", context: context)
        }
    }

    // MARK: Desktop

    static func openApp(at url: URL, _ context: LauncherContext) async {
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            log("system: couldn't open \(url.path): \(error.localizedDescription)")
            SystemHUD.report("Couldn't open \(url.deletingPathExtension().lastPathComponent)",
                             symbol: "exclamationmark.triangle", context: context)
        }
    }

    private static let missionControlApp = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    static func missionControl(_ context: LauncherContext) async {
        if sendDockNotification("com.apple.expose.awake") { return }
        await openApp(at: missionControlApp, context)
    }

    /// The Dock's show-desktop, or Mission Control.app's ("1" is its argument for it).
    static func showDesktop(_ context: LauncherContext) async {
        if sendDockNotification("com.apple.showdesktop.awake") { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["1"]
        do {
            _ = try await NSWorkspace.shared.openApplication(at: missionControlApp, configuration: configuration)
        } catch {
            log("system: show desktop failed: \(error.localizedDescription)")
            SystemHUD.report("Couldn't show the desktop", symbol: "exclamationmark.triangle", context: context)
        }
    }

    // MARK: Wi-Fi

    private static let networksetup = "/usr/sbin/networksetup"
    /// The Wi-Fi interface ("en0"), found once.
    private static var wifiDevice: String?

    private static func wifiInterface() async -> String? {
        if let wifiDevice { return wifiDevice }
        let ports = await runTool(networksetup, ["-listallhardwareports"])
        wifiDevice = LauncherSystemOutput.wifiDevice(inHardwarePorts: ports.output)
        return wifiDevice
    }

    private static func wifiPower(_ device: String) async -> Bool? {
        LauncherSystemOutput.wifiPower(await runTool(networksetup, ["-getairportpower", device]).output)
    }

    /// Wi-Fi on, off, or (nil) the other way round; it reads the power back to say what happened.
    static func setWiFi(_ on: Bool?, _ context: LauncherContext) async {
        guard let device = await wifiInterface() else {
            SystemHUD.report("This Mac has no Wi-Fi", symbol: "wifi.slash", context: context)
            return
        }
        var target = on
        if target == nil {
            guard let current = await wifiPower(device) else {
                SystemHUD.report("Couldn't read whether Wi-Fi is on", symbol: "exclamationmark.triangle",
                                 context: context)
                return
            }
            target = !current
        }
        let turnOn = target ?? true
        let result = await runTool(networksetup, ["-setairportpower", device, turnOn ? "on" : "off"])
        if await wifiPower(device) == turnOn {
            SystemHUD.report(turnOn ? "Wi-Fi on" : "Wi-Fi off", symbol: turnOn ? "wifi" : "wifi.slash",
                             context: context)
        } else {
            // macOS can require an administrator for it (System Settings → Wi-Fi → Advanced).
            let said = (result.output + result.error).trimmingCharacters(in: .whitespacesAndNewlines)
            log("system: networksetup -setairportpower \(turnOn ? "on" : "off") failed: \(said.prefix(200))")
            SystemHUD.report("Couldn't turn Wi-Fi \(turnOn ? "on" : "off")", symbol: "exclamationmark.triangle",
                             context: context)
        }
    }

    // MARK: Finder and Dock

    /// Finder's "show all files" setting flipped, then Finder restarted so that it reads it.
    static func toggleHiddenFiles(_ context: LauncherContext) async {
        let read = await runTool("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"])
        let shown = LauncherSystemOutput.defaultsBool(read.output) ?? false
        let write = await runTool("/usr/bin/defaults",
                                  ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", shown ? "false" : "true"])
        guard write.succeeded else {
            log("system: defaults write AppleShowAllFiles failed: \(write.error.prefix(200))")
            SystemHUD.report("Couldn't change Finder's setting", symbol: "exclamationmark.triangle", context: context)
            return
        }
        _ = await runTool("/usr/bin/killall", ["Finder"])
        SystemHUD.report(shown ? "Finder hides hidden files" : "Finder shows hidden files",
                         symbol: shown ? "eye.slash" : "eye", context: context)
    }

    /// Finder or the Dock quit, and macOS starts them again at once.
    static func restartProcess(_ name: String, _ context: LauncherContext) async {
        let result = await runTool("/usr/bin/killall", [name])
        SystemHUD.report(result.succeeded ? "\(name) restarted" : "\(name) isn't running",
                         symbol: "arrow.triangle.2.circlepath", context: context)
    }

    // MARK: Keep Awake

    /// `caffeinate -dim` while Keep Awake is on: no display, idle or disk sleep.
    private static var caffeinate: Process?
    private(set) static var awakeSince: Date?

    static func toggleKeepAwake(_ context: LauncherContext) {
        if awakeSince != nil {
            stopKeepingAwake()
            SystemHUD.report("The Mac can sleep again", symbol: "moon.zzz", context: context)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w: it ends with DigUp, even if DigUp crashes.
        process.arguments = ["-dim", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        process.terminationHandler = { ended in
            Task { @MainActor in
                if caffeinate === ended {
                    caffeinate = nil
                    awakeSince = nil
                }
            }
        }
        do {
            try process.run()
        } catch {
            log("system: caffeinate didn't start: \(error.localizedDescription)")
            SystemHUD.report("Couldn't keep the Mac awake", symbol: "exclamationmark.triangle", context: context)
            return
        }
        caffeinate = process
        awakeSince = Date()
        log("system: keeping awake (caffeinate \(process.processIdentifier))")
        SystemHUD.report("Keeping the Mac awake", symbol: "cup.and.saucer.fill", context: context)
    }

    static func stopKeepingAwake() {
        if let caffeinate, caffeinate.isRunning { caffeinate.terminate() }
        caffeinate = nil
        awakeSince = nil
    }

    // MARK: Clipboard

    static func clearClipboard(_ context: LauncherContext) {
        NSPasteboard.general.clearContents()
        SystemHUD.report("Clipboard cleared", symbol: "clipboard", context: context)
    }
}

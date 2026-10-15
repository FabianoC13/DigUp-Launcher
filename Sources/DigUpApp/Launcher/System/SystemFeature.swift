import AppKit
import DigUpKit
import SwiftUI

/// System commands: lock, sleep, restart, dark mode, empty trash, volume, eject…
///
/// Each is a root-search item ("cmd:<key>"). Its action hides the panel first, so the app you came from has the
/// keyboard back, then runs; what it has to say afterwards ("Volume 50%", "Ejected USB") shows in `SystemHUD`.
enum SystemFeature: LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [CommandsProvider()]
    }

    static func start(_ launcher: Launcher) {
        // Keep Awake's caffeinate goes when DigUp quits (and with `-w` it would anyway, even after a crash).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { stopKeepingAwake() }
        }
    }

    /// One system command: how the root search lists it and what it does.
    struct Command {
        /// The stable part of the item id ("lock-screen" → "cmd:lock-screen").
        let key: String
        let title: String
        var keywords: [String] = []
        let symbol: String
        /// What it needs from macOS, shown under the preview ("Accessibility", "Automation: Finder").
        var needs: String?
        var destructive = false
        /// Shown under the title while it says something (Keep Awake: since when).
        var subtitle: @MainActor () -> String? = { nil }
        /// The action's name when it isn't the title (Keep Awake: "Stop Keeping Awake").
        var actionTitle: @MainActor () -> String? = { nil }
        let run: @MainActor (LauncherContext) async -> Void

        var id: String { "\(CommandsProvider.prefix):\(key)" }

        func item(score: Double = 0.5) -> LauncherItem {
            let action = LauncherAction(id: "run", title: actionTitle() ?? title, symbol: symbol,
                                        style: destructive ? .destructive : .normal, run: run)
            var metadata: [(label: String, value: String)] = []
            if let needs { metadata.append(("Needs", needs)) }
            return LauncherItem(id: id, title: title, subtitle: subtitle(), icon: .symbol(symbol), accessory: "Command",
                                score: score, actions: [action], metadata: metadata, tracksUsage: true)
        }
    }

    /// The app in front, that "other apps" and window commands mean: the one the panel opened over, or, when a
    /// hotkey ran the command with the panel closed, the frontmost one.
    static func appInFront(_ context: LauncherContext) -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return front
        }
        return context.previousApp
    }

    /// Every command, in the order they're listed when several match equally.
    static let commands: [Command] = powerCommands + trashCommands + appearanceCommands + soundCommands
        + mediaCommands + diskCommands + appCommands + desktopCommands + networkCommands + finderCommands
        + otherCommands

    /// The root search's "cmd" items: the commands whose name or keywords match.
    private final class CommandsProvider: LauncherProvider {
        static let prefix = "cmd"
        let id = prefix

        func items(for query: LauncherQuery) async -> [LauncherItem] {
            guard !query.isEmpty else { return [] }
            // "volume 30": Set Volume to 30% first (and not twice when it's one of the presets).
            let typed = LauncherVolumeSettings.requestedLevel(query.text).map { SystemFeature.volumeCommand($0) }
            let matches = SystemFeature.commands.compactMap { command in
                command.id == typed?.id ? nil
                    : query.match(command.title, keywords: command.keywords).map { command.item(score: $0) }
            }
            return (typed.map { [$0.item(score: 1)] } ?? []) + matches
        }

        func item(id: String) async -> LauncherItem? {
            if let command = SystemFeature.commands.first(where: { $0.id == id }) { return command.item() }
            // A typed level someone made a favorite or gave a hotkey ("cmd:volume-30").
            let prefix = "\(Self.prefix):volume-"
            guard id.hasPrefix(prefix), let level = Int(id.dropFirst(prefix.count)), (0...100).contains(level) else {
                return nil
            }
            return SystemFeature.volumeCommand(level).item()
        }
    }
}

// MARK: The commands

extension SystemFeature {
    private static let powerCommands: [Command] = [
        Command(key: "lock-screen", title: "Lock Screen", keywords: ["lock", "away", "secure"], symbol: "lock.fill",
                run: { lockScreen($0) }),
        Command(key: "sleep", title: "Sleep", keywords: ["suspend", "power", "standby"], symbol: "moon.zzz.fill",
                run: { await sleepNow($0) }),
        Command(key: "sleep-displays", title: "Sleep Displays",
                keywords: ["screen off", "monitor off", "turn off display", "blank"], symbol: "display",
                run: { await sleepDisplays($0) }),
        Command(key: "restart", title: "Restart", keywords: ["reboot", "power"], symbol: "arrow.clockwise.circle.fill",
                needs: "Automation (loginwindow or System Events)", run: { await endSession(.restart, $0) }),
        Command(key: "shut-down", title: "Shut Down", keywords: ["power off", "turn off", "shutdown"],
                symbol: "power", needs: "Automation (loginwindow or System Events)",
                run: { await endSession(.shutDown, $0) }),
        Command(key: "log-out", title: "Log Out", keywords: ["sign out", "logout", "user"],
                symbol: "rectangle.portrait.and.arrow.right", needs: "Automation (loginwindow or System Events)",
                run: { await endSession(.logOut, $0) }),
        Command(key: "screen-saver", title: "Start Screen Saver", keywords: ["screensaver"], symbol: "sparkles.tv",
                run: { await startScreenSaver($0) }),
        Command(key: "low-power-mode", title: "Toggle Low Power Mode",
                keywords: ["energy saver", "battery saver", "power mode", "low power"], symbol: "leaf.fill",
                needs: "An administrator's password", run: { await toggleLowPowerMode($0) }),
    ]

    private static let trashCommands: [Command] = [
        Command(key: "empty-trash", title: "Empty Trash", keywords: ["bin", "delete", "clean", "garbage"],
                symbol: "trash.fill", needs: "Automation (Finder)", destructive: true,
                run: { await emptyTrash($0) }),
        Command(key: "open-trash", title: "Open Trash", keywords: ["bin", "deleted", "garbage"], symbol: "trash",
                run: { _ in openTrash() }),
    ]

    private static let appearanceCommands: [Command] = [
        Command(key: "toggle-dark-mode", title: "Toggle Dark Mode",
                keywords: ["appearance", "light mode", "theme", "system appearance"],
                symbol: "circle.lefthalf.filled", needs: "Automation (System Events)",
                run: { await setDarkMode(nil, $0) }),
        Command(key: "dark-mode-on", title: "Turn On Dark Mode", keywords: ["appearance", "night", "theme"],
                symbol: "moon.fill", needs: "Automation (System Events)", run: { await setDarkMode(true, $0) }),
        Command(key: "dark-mode-off", title: "Turn Off Dark Mode", keywords: ["light mode", "appearance", "theme"],
                symbol: "sun.max.fill", needs: "Automation (System Events)", run: { await setDarkMode(false, $0) }),
        Command(key: "toggle-night-shift", title: "Toggle Night Shift",
                keywords: ["night light", "blue light", "warm colors", "display tint"], symbol: "moon.circle.fill",
                run: { toggleNightShift($0) }),
    ]

    private static let soundCommands: [Command] = [
        Command(key: "volume-up", title: "Turn Volume Up", keywords: ["louder", "sound", "increase volume"],
                symbol: "speaker.wave.3.fill", run: { await stepVolume(up: true, $0) }),
        Command(key: "volume-down", title: "Turn Volume Down", keywords: ["quieter", "sound", "decrease volume"],
                symbol: "speaker.wave.1.fill", run: { await stepVolume(up: false, $0) }),
        Command(key: "mute", title: "Mute", keywords: ["sound off", "silence", "volume"], symbol: "speaker.slash.fill",
                run: { await setMuted(true, $0) }),
        Command(key: "unmute", title: "Unmute", keywords: ["sound on", "volume"], symbol: "speaker.wave.2.fill",
                run: { await setMuted(false, $0) }),
        Command(key: "toggle-mute", title: "Toggle Mute", keywords: ["sound", "silence", "volume"],
                symbol: "speaker.slash", run: { await setMuted(nil, $0) }),
    ] + [0, 25, 50, 75, 100].map { volumeCommand($0) } + [
        Command(key: "toggle-microphone", title: "Toggle Microphone Mute",
                keywords: ["mic", "input", "mute microphone", "unmute microphone"], symbol: "mic.slash.fill",
                run: { await toggleMicrophone($0) }),
    ]

    private static let mediaCommands: [Command] = [
        Command(key: "play-pause", title: "Play / Pause", keywords: ["music", "media", "resume", "stop"],
                symbol: "playpause.fill", needs: "Accessibility", run: { mediaKey(.playPause, $0) }),
        Command(key: "next-track", title: "Next Track", keywords: ["skip", "song", "music", "media"],
                symbol: "forward.fill", needs: "Accessibility", run: { mediaKey(.next, $0) }),
        Command(key: "previous-track", title: "Previous Track", keywords: ["back", "song", "music", "media"],
                symbol: "backward.fill", needs: "Accessibility", run: { mediaKey(.previous, $0) }),
    ]

    private static let diskCommands: [Command] = [
        Command(key: "eject-all", title: "Eject All Disks",
                keywords: ["unmount", "usb", "drive", "volume", "disk image", "external"], symbol: "eject.fill",
                run: { await ejectAll($0) }),
    ]

    private static let appCommands: [Command] = [
        Command(key: "quit-all", title: "Quit All Apps", keywords: ["close all", "applications", "terminate"],
                symbol: "xmark.circle.fill", destructive: true, run: { quitApps(keepingFrontmost: false, $0) }),
        Command(key: "quit-others", title: "Quit Other Apps",
                keywords: ["quit all apps except frontmost", "close others", "applications"],
                symbol: "xmark.circle", destructive: true, run: { quitApps(keepingFrontmost: true, $0) }),
        Command(key: "hide-all", title: "Hide All Apps", keywords: ["applications", "clear screen"],
                symbol: "eye.slash.fill", run: { hideApps(keepingFrontmost: false, $0) }),
        Command(key: "hide-others", title: "Hide Other Apps",
                keywords: ["hide all apps except frontmost", "focus", "applications"], symbol: "eye.slash",
                run: { hideApps(keepingFrontmost: true, $0) }),
        Command(key: "unhide-all", title: "Unhide All Apps", keywords: ["show all", "applications", "hidden"],
                symbol: "eye.fill", run: { unhideApps($0) }),
    ]

    private static let desktopCommands: [Command] = [
        Command(key: "mission-control", title: "Open Mission Control", keywords: ["spaces", "expose", "overview"],
                symbol: "rectangle.3.group.fill", run: { await missionControl($0) }),
        Command(key: "show-desktop", title: "Show Desktop", keywords: ["desktop", "clear windows", "hide windows"],
                symbol: "menubar.dock.rectangle", run: { await showDesktop($0) }),
    ] + (launchpadApp.map { app in
        [Command(key: "launchpad", title: "Open \(app.deletingPathExtension().lastPathComponent)",
                 keywords: ["launchpad", "apps", "applications grid"], symbol: "square.grid.3x3.fill",
                 run: { await openApp(at: app, $0) })]
    } ?? [])

    private static let networkCommands: [Command] = [
        Command(key: "toggle-wifi", title: "Toggle Wi-Fi", keywords: ["wifi", "wireless", "wlan", "internet", "airport"],
                symbol: "wifi", run: { await setWiFi(nil, $0) }),
        Command(key: "wifi-on", title: "Turn Wi-Fi On", keywords: ["wifi", "wireless", "internet"], symbol: "wifi",
                run: { await setWiFi(true, $0) }),
        Command(key: "wifi-off", title: "Turn Wi-Fi Off", keywords: ["wifi", "wireless", "offline"],
                symbol: "wifi.slash", run: { await setWiFi(false, $0) }),
    ]

    private static let finderCommands: [Command] = [
        Command(key: "toggle-hidden-files", title: "Toggle Hidden Files",
                keywords: ["show hidden files", "dotfiles", "invisible", "finder"], symbol: "eye.square",
                run: { await toggleHiddenFiles($0) }),
        Command(key: "restart-finder", title: "Restart Finder", keywords: ["relaunch", "kill finder"],
                symbol: "arrow.triangle.2.circlepath", run: { await restartProcess("Finder", $0) }),
        Command(key: "restart-dock", title: "Restart Dock", keywords: ["relaunch", "kill dock"],
                symbol: "dock.rectangle", run: { await restartProcess("Dock", $0) }),
    ]

    private static let otherCommands: [Command] = [
        Command(key: "keep-awake", title: "Keep Awake",
                keywords: ["caffeinate", "prevent sleep", "no sleep", "coffee", "stay awake"],
                symbol: "cup.and.saucer.fill",
                subtitle: { awakeSince.map { "On since \($0.formatted(date: .omitted, time: .shortened))" } },
                actionTitle: { awakeSince == nil ? nil : "Stop Keeping Awake" },
                run: { toggleKeepAwake($0) }),
        Command(key: "clear-clipboard", title: "Clear Clipboard", keywords: ["empty clipboard", "pasteboard"],
                symbol: "clipboard", run: { clearClipboard($0) }),
    ]

    /// Set Volume to `level`%: the presets, and any level typed as "volume 30".
    static func volumeCommand(_ level: Int) -> Command {
        Command(key: "volume-\(level)", title: "Set Volume to \(level)%", keywords: ["sound", "level"],
                symbol: volumeSymbol(level), run: { await setVolume(level, $0) })
    }

    static func volumeSymbol(_ level: Int) -> String {
        switch level {
        case 0: "speaker.fill"
        case ..<34: "speaker.wave.1.fill"
        case ..<67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    /// Launchpad before macOS 26, Apps since.
    private static let launchpadApp: URL? = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

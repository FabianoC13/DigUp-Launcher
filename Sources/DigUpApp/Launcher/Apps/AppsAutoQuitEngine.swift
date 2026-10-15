import AppKit
import CoreAudio
import DigUpKit

/// Auto Quit: the apps on the list quit by themselves once they've been in the background for their minutes. Being
/// in front resets an app's clock. Nothing is quit while a microphone is recording (a call, a voice memo), and the
/// music and video players aren't while sound is playing. Apps are asked to quit like ⌘Q, so one with unsaved work
/// asks first; it isn't asked again until another full period has passed.
final class AppsAutoQuitEngine {
    /// When each app was last in front (set as it leaves the foreground).
    private var lastActive: [String: Date] = [:]
    /// When each app was last asked to quit.
    private var asked: [String: Date] = [:]
    private var watchedSince = Date()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var preferences = AppsPreferences()

    /// How often the clocks are checked.
    static let checkInterval: TimeInterval = 20

    var isRunning: Bool { timer != nil }

    /// Starts, stops or updates Auto Quit for the current settings.
    func apply(_ preferences: AppsPreferences) {
        self.preferences = preferences
        let wanted = preferences.autoQuitEnabled && !preferences.autoQuitApps.isEmpty
        if wanted, !isRunning {
            start()
        } else if !wanted, isRunning {
            stop()
        }
    }

    private func start() {
        watchedSince = Date()
        lastActive = [:]
        asked = [:]
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier
                MainActor.assumeIsolated {
                    guard let self, let bundleID else { return }
                    // Coming to the front or leaving it, the app was just in use: its clock starts over.
                    self.lastActive[bundleID] = Date()
                    self.asked[bundleID] = nil
                }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let bundleID else { return }
                self.lastActive[bundleID] = nil
                self.asked[bundleID] = nil
            }
        })
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log("apps: Auto Quit on for \(preferences.autoQuitApps.count) apps")
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
        log("apps: Auto Quit off")
    }

    /// Asks the apps whose time is up to quit.
    private func check() {
        let rules = preferences.autoQuitApps
        guard !rules.isEmpty else { return }
        let listed = Set(rules.map(\.bundleID))
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier.map(listed.contains) == true && !app.isTerminated
        }
        guard !apps.isEmpty else { return }
        var paused = Set<String>()
        if AppsAudio.isRunning(input: true) {
            // Recording or on a call: quitting anything now could interrupt it.
            paused = listed
        } else if AppsAudio.isRunning(input: false) {
            paused = listed.intersection(AppsAutoQuit.players)
        }
        let running = apps.compactMap { app in
            app.bundleIdentifier.map { AppsAutoQuit.RunningApp(bundleID: $0, lastActive: lastActive[$0]) }
        }
        let now = Date()
        let due = AppsAutoQuit.due(
            running: running, rules: rules, defaultMinutes: preferences.autoQuitMinutes,
            frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, paused: paused, asked: asked,
            watchedSince: watchedSince, now: now)
        for bundleID in due {
            asked[bundleID] = now
            for app in apps where app.bundleIdentifier == bundleID {
                log("apps: Auto Quit asks \(bundleID) to quit")
                app.terminate()
            }
        }
    }
}

/// Whether a microphone or the speakers are in use by any app (Core Audio's "running somewhere").
nonisolated enum AppsAudio {
    static func isRunning(input: Bool) -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
                                         &device) == noErr, device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

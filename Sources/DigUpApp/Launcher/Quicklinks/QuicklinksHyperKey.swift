import AppKit
import Carbon.HIToolbox
import DigUpKit

/// The Hyper Key (off until you turn it on in Settings): Caps Lock acts as ⌃⌥⇧⌘ (or ⌃⌥⌘), so hyper+letter shortcuts,
/// item hotkeys among them, never clash with an app's own.
///
/// Two parts: `hidutil` maps Caps Lock to F18 (keeping any mappings you already have), and an event tap (which needs
/// Accessibility) swallows F18 and adds the four modifiers to every key pressed while it's held. Turning it off, or
/// quitting DigUp, puts Caps Lock back the way it was.
final class QuicklinksHyperKey {
    static let shared = QuicklinksHyperKey()

    private var store: QuicklinksStore?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state = QuicklinksHyperKeyState()
    /// What a key pressed with the Hyper Key gets.
    private var hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    private var quickPress = QuicklinksSettings.QuickPress.nothing
    /// Waits for the Accessibility permission after you turned it on without it.
    private var permissionTimer: Timer?
    private var terminateObserver: NSObjectProtocol?

    nonisolated private static let hidutil = URL(fileURLWithPath: "/usr/bin/hidutil")

    private init() {}

    func start(store: QuicklinksStore) {
        self.store = store
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuicklinksHyperKey.shared.restoreOnQuit() }
        }
        if store.settings.hyperKeyEnabled {
            enable()
        } else if store.settings.hyperMappingApplied {
            // DigUp didn't get to put Caps Lock back last time (it crashed, or was force quit).
            Task { await removeMapping() }
        }
    }

    /// The settings switch.
    func setEnabled(_ on: Bool) {
        guard let store else { return }
        store.updateSettings { $0.hyperKeyEnabled = on }
        log("quicklinks: hyper key \(on ? "on" : "off")")
        if on { enable() } else { disable() }
    }

    /// The other settings (⇧ included, what a quick press does) took effect.
    func settingsChanged() {
        guard let settings = store?.settings else { return }
        hyperFlags = [.maskControl, .maskAlternate, .maskCommand]
        if settings.hyperIncludesShift { hyperFlags.insert(.maskShift) }
        quickPress = settings.hyperQuickPress
    }

    // MARK: Turning it on and off

    private func enable() {
        guard let store else { return }
        settingsChanged()
        guard Accessibility.isTrusted(prompt: true) else {
            store.hyperKeyStatus = .needsAccessibility
            waitForPermission()
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        guard installTap() else {
            // Some macOS versions want Input Monitoring for a keyboard tap as well.
            if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
            store.hyperKeyStatus = .failed("macOS didn't let DigUp watch the keyboard: allow DigUp in Privacy & "
                                           + "Security → Input Monitoring, then turn the Hyper Key off and on")
            return
        }
        Task {
            if let problem = await applyMapping() {
                removeTap()
                store.hyperKeyStatus = .failed(problem)
            } else {
                store.hyperKeyStatus = store.settings.hyperKeyEnabled ? .on : .off
            }
        }
    }

    private func disable() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        removeTap()
        store?.hyperKeyStatus = .off
        Task { await removeMapping() }
    }

    /// Checks every couple of seconds whether DigUp was allowed in Accessibility, and turns the Hyper Key on then.
    private func waitForPermission() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let hyper = QuicklinksHyperKey.shared
                guard hyper.store?.settings.hyperKeyEnabled == true else {
                    hyper.permissionTimer?.invalidate()
                    hyper.permissionTimer = nil
                    return
                }
                if Accessibility.isTrusted() { hyper.enable() }
            }
        }
    }

    // MARK: The event tap

    private func installTap() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: quicklinksHyperTap,
                                           userInfo: me) else {
            log("quicklinks: hyper key event tap couldn't be created")
            return false
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = runLoopSource
        state.reset()
        return true
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        state.reset()
    }

    /// One key event from the tap: what goes on to the apps (nil: nothing).
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS switches a slow tap off; on again, and a release may have been missed meanwhile.
            state.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let time = TimeInterval(event.timestamp) / 1_000_000_000
        switch state.handle(keyCode: keyCode, isDown: type == .keyDown, at: time) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .quickPress:
            if quickPress == .escape { Keystrokes.post(keyCode: CGKeyCode(kVK_Escape)) }
            return nil
        case .addModifiers:
            event.flags = event.flags.union(hyperFlags)
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: Caps Lock → F18

    /// Puts Caps Lock → F18 among the current mappings. Nil when done, else why not.
    private func applyMapping() async -> String? {
        guard let store else { return "Not started" }
        let result: Result<UInt64?, QuicklinksHyperKeyError> = await Task.detached(priority: .userInitiated) {
            do {
                let current = QuicklinksHyperKeyMapping.parse(try Self.run(["property", "--get", "UserKeyMapping"]))
                let (mappings, previous) = QuicklinksHyperKeyMapping.enabling(current)
                _ = try Self.run(["property", "--set", QuicklinksHyperKeyMapping.json(mappings)])
                return .success(previous)
            } catch let error as QuicklinksHyperKeyError {
                return .failure(error)
            } catch {
                return .failure(QuicklinksHyperKeyError(message: error.localizedDescription))
            }
        }.value
        switch result {
        case .success(let previous):
            store.updateSettings { settings in
                // Keep the first mapping it replaced: after a crash, the current one may be DigUp's own.
                if !settings.hyperMappingApplied { settings.previousCapsLock = previous }
                settings.hyperMappingApplied = true
            }
            log("quicklinks: caps lock → F18")
            return nil
        case .failure(let error):
            log("quicklinks: hidutil failed: \(error.message)")
            return "Caps Lock couldn't be remapped (\(error.message))"
        }
    }

    /// Takes Caps Lock → F18 out and puts back what Caps Lock did before.
    private func removeMapping() async {
        guard let store else { return }
        let previous = store.settings.previousCapsLock
        let result: Result<Void, QuicklinksHyperKeyError> = await Task.detached(priority: .userInitiated) {
            Self.restore(previous: previous)
        }.value
        switch result {
        case .success:
            store.updateSettings {
                $0.hyperMappingApplied = false
                $0.previousCapsLock = nil
            }
            log("quicklinks: caps lock mapping restored")
        case .failure(let error):
            log("quicklinks: hidutil failed: \(error.message)")
        }
    }

    /// At quit: the tap goes with the app, but the mapping would outlive it, so it's put back now (synchronously,
    /// it's quick).
    private func restoreOnQuit() {
        guard let store, store.settings.hyperMappingApplied else { return }
        removeTap()
        if case .success = Self.restore(previous: store.settings.previousCapsLock) {
            store.updateSettings(now: true) {
                $0.hyperMappingApplied = false
                $0.previousCapsLock = nil
            }
            log("quicklinks: caps lock mapping restored at quit")
        }
    }

    nonisolated private static func restore(previous: UInt64?) -> Result<Void, QuicklinksHyperKeyError> {
        do {
            let current = QuicklinksHyperKeyMapping.parse(try run(["property", "--get", "UserKeyMapping"]))
            let mappings = QuicklinksHyperKeyMapping.disabling(current, restoring: previous)
            guard mappings != current else { return .success(()) }
            _ = try run(["property", "--set", QuicklinksHyperKeyMapping.json(mappings)])
            return .success(())
        } catch let error as QuicklinksHyperKeyError {
            return .failure(error)
        } catch {
            return .failure(QuicklinksHyperKeyError(message: error.localizedDescription))
        }
    }

    /// Runs hidutil and returns what it printed.
    nonisolated private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = hidutil
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw QuicklinksHyperKeyError(message: "hidutil exited with \(process.terminationStatus)")
        }
        return text
    }
}

nonisolated struct QuicklinksHyperKeyError: Error, Sendable {
    let message: String
}

/// The event tap's callback: its source is on the main run loop, so it runs on the main thread.
nonisolated private func quicklinksHyperTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let pointer = userInfo else { return Unmanaged.passUnretained(event) }
    nonisolated(unsafe) let event = event
    nonisolated(unsafe) let owner = pointer
    nonisolated(unsafe) var result: Unmanaged<CGEvent>?
    MainActor.assumeIsolated {
        result = Unmanaged<QuicklinksHyperKey>.fromOpaque(owner).takeUnretainedValue().handle(type, event)
    }
    return result
}

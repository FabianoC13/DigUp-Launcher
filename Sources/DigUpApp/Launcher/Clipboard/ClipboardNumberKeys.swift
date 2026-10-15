import AppKit
import Carbon.HIToolbox

/// DigUp's fn shortcuts, anywhere: fn+1…fn+9 paste the 1st…9th most recent copy in Clipboard History into the app in
/// front without opening the panel (when that setting is on), and fn+S turns Stealth mode on and off. The numbers stay put: pasting this way doesn't move the entry to the top, and the clipboard is
/// put back as it was afterwards, so ⌘V still pastes your last copy.
///
/// An event tap that can swallow keys needs Accessibility; until it's allowed, this checks again every few seconds.
final class ClipboardNumberKeys {
    static let shared = ClipboardNumberKeys()

    /// The digit row's key codes, 1 to 9.
    nonisolated static let digitKeys: [Int64: Int] = [
        Int64(kVK_ANSI_1): 1, Int64(kVK_ANSI_2): 2, Int64(kVK_ANSI_3): 3, Int64(kVK_ANSI_4): 4, Int64(kVK_ANSI_5): 5,
        Int64(kVK_ANSI_6): 6, Int64(kVK_ANSI_7): 7, Int64(kVK_ANSI_8): 8, Int64(kVK_ANSI_9): 9,
    ]

    /// For pasting past the panel when it's open.
    weak var launcher: Launcher?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?

    /// fn+S, which turns Stealth mode on and off.
    nonisolated static let stealthKey = Int64(kVK_ANSI_S)

    /// The tap runs whenever Accessibility allows (fn+S is always on); fn+1…fn+9 follow their setting.
    func update() {
        start()
    }

    /// fn+S: Stealth mode on or off, said in the panel when it's open, else in a bubble.
    fileprivate func toggleStealth() {
        let appearance = PanelAppearance.shared
        appearance.stealth.toggle()
        let message = appearance.stealth ? "Stealth mode on" : "Normal mode"
        if let panel = launcher?.panel, panel.isVisible {
            panel.flashNote(message)
        } else {
            SystemHUD.show(message, symbol: appearance.stealth ? "eye.slash" : "eye")
        }
        log("panel: \(message.lowercased()) (fn+S)")
    }

    private func start() {
        guard tap == nil else { return }
        guard Accessibility.isTrusted() else {
            retryWhenAllowed()
            return
        }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: numberKeysCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("clipboard: couldn't create the fn+number event tap")
            retryWhenAllowed()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        retryTimer?.invalidate()
        retryTimer = nil
        log("fn keys: fn+S for Stealth, fn+1…fn+9 paste from the history")
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func retryWhenAllowed() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                let keys = ClipboardNumberKeys.shared
                guard Accessibility.isTrusted() else { return }
                keys.retryTimer?.invalidate()
                keys.retryTimer = nil
                keys.start()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    /// The tap timed out (a slow callback) or was turned off by the user: back on.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Pastes the `number`th most recent entry into the app in front (the one you came from, when DigUp's panel is
    /// open) and puts the clipboard back.
    func paste(_ number: Int) {
        let store = ClipboardStore.shared
        let recent = store.byRecency
        guard recent.indices.contains(number - 1) else {
            NSSound.beep()
            return
        }
        let saved = SnippetPaster.savedItems()
        guard store.write(recent[number - 1]) else {
            NSSound.beep()
            return
        }
        // Not a new copy, and not a reason to move the entry up: the numbers stay as they were.
        store.ignoreCurrentPasteboard()
        let viaPanel = launcher?.panel?.isVisible == true
        if viaPanel, let context = launcher?.panel?.context {
            context.pasteClipboard()   // hides the panel, brings back the app you came from, ⌘V
        } else {
            Keystrokes.post(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(viaPanel ? 700 : 400))
            SnippetPaster.restore(saved)
            store.ignoreCurrentPasteboard()
        }
    }
}

/// Swallows fn+1…fn+9 (and nothing else) and pastes on the main run loop, where the tap runs.
private nonisolated func numberKeysCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<ClipboardNumberKeys>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { keys.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    let others: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    guard flags.contains(.maskSecondaryFn), flags.intersection(others).isEmpty else {
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    if code == ClipboardNumberKeys.stealthKey {
        if !repeated { MainActor.assumeIsolated { keys.toggleStealth() } }
        return nil
    }
    guard let number = ClipboardNumberKeys.digitKeys[code],
          MainActor.assumeIsolated({ ClipboardStore.shared.settings.numberKeys }) else {
        return Unmanaged.passUnretained(event)
    }
    if !repeated { MainActor.assumeIsolated { keys.paste(number) } }
    return nil
}

import AppKit
import Carbon.HIToolbox
import DigUpKit
import Observation

/// Text expansion: watches typing through a listen-only event tap and, when what was just typed ends with a snippet's
/// keyword, deletes the keyword and pastes the snippet. It keeps only the last few characters, never in password
/// fields (secure input), and never in DigUp's own windows.
@Observable
final class SnippetExpander {
    static let shared = SnippetExpander()

    /// The tap is on and watching.
    private(set) var running = false
    /// Why it isn't running although it's on (a missing permission), for Settings.
    private(set) var problem: String?

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var matcher = SnippetKeywordMatcher()
    @ObservationIgnored private var snippetIDs: [String: String] = [:]
    @ObservationIgnored private var expanding = false
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    /// Takes the current keywords and settings, and starts or stops watching.
    func update() {
        let store = SnippetStore.shared
        snippetIDs = Dictionary(store.snippets.compactMap { snippet in snippet.keyword.map { ($0, snippet.id) } },
                                uniquingKeysWith: { first, _ in first })
        matcher.setKeywords(Array(snippetIDs.keys))
        matcher.trigger = store.settings.trigger
        matcher.expandWithinWords = store.settings.expandWithinWords
        if store.settings.expansionEnabled, !snippetIDs.isEmpty { start() } else { stop() }
    }

    private func start() {
        guard tap == nil else { return }
        guard Accessibility.isTrusted() else {
            problem = "Text expansion needs Accessibility: allow DigUp in System Settings → Privacy & Security → Accessibility."
            retryWhenAllowed()
            return
        }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: snippetTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            problem = "macOS didn't let DigUp watch typing: allow it in System Settings → Privacy & Security → Input Monitoring."
            if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
            retryWhenAllowed()
            log("snippets: couldn't create the event tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        retryTimer?.invalidate()
        retryTimer = nil
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.matcher.reset() }
        }
        matcher.reset()
        running = true
        problem = nil
        log("snippets: text expansion on (\(snippetIDs.count) keywords)")
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        problem = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        running = false
        log("snippets: text expansion off")
    }

    /// Checks every few seconds whether the permission was given, and starts then.
    private func retryWhenAllowed() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Accessibility.isTrusted() else { return }
                self.retryTimer?.invalidate()
                self.retryTimer = nil
                self.update()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: Typing

    fileprivate func handle(_ event: TapEvent) {
        switch event.type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            matcher.reset()
            return
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click may have moved the caret.
            matcher.reset()
            return
        case .keyDown:
            break
        default:
            return
        }
        guard !event.ownKey, !expanding else { return }
        // Password fields, and DigUp's own windows (the snippet editor would expand the keyword being defined).
        if IsSecureEventInputEnabled() || NSApp.isActive {
            matcher.reset()
            return
        }
        if event.flags.contains(.maskCommand) || event.flags.contains(.maskControl) {
            matcher.reset()
            return
        }
        switch event.keyCode {
        case kVK_Delete:
            matcher.deleteBackward()
            return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
             kVK_ForwardDelete, kVK_Escape, kVK_Tab, kVK_Return, kVK_ANSI_KeypadEnter:
            matcher.reset()
            return
        default:
            break
        }
        let typed = event.characters
        guard !typed.isEmpty else { return }
        guard let match = matcher.typed(typed), let id = snippetIDs[match.keyword],
              let snippet = SnippetStore.shared.snippet(id) else { return }
        expand(snippet, match)
    }

    private func expand(_ snippet: Snippet, _ match: SnippetKeywordMatcher.Match) {
        expanding = true
        let target = NSWorkspace.shared.frontmostApplication
        Task {
            // Let the app take the keyword's last key first.
            try? await Task.sleep(for: .milliseconds(25))
            await SnippetPaster.paste(snippet, into: target, deleteCount: match.deleteCount, suffix: match.delimiter)
            expanding = false
            matcher.reset()
        }
    }
}

/// What the expander needs from one tapped event, read on the tap's thread so the event itself stays there.
fileprivate nonisolated struct TapEvent: Sendable {
    var type: CGEventType
    var keyCode = 0
    var flags: CGEventFlags = []
    /// One of DigUp's own key presses (`SnippetPaster.eventMarker`).
    var ownKey = false
    var characters = ""

    init(_ type: CGEventType, _ event: CGEvent) {
        self.type = type
        guard type == .keyDown else { return }
        keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        flags = event.flags
        ownKey = event.getIntegerValueField(.eventSourceUserData) == SnippetPaster.eventMarker
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length,
                                       unicodeString: &buffer)
        characters = String(utf16CodeUnits: buffer, count: length)
    }
}

/// The event tap's callback (on the main run loop): hands the event to the expander and lets it through unchanged.
private nonisolated func snippetTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let tapped = TapEvent(type, event)
        let expander = Unmanaged<SnippetExpander>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated { expander.handle(tapped) }
    }
    return Unmanaged.passUnretained(event)
}

import Foundation

/// The key remapping behind the Hyper Key: Caps Lock becomes F18 (`hidutil`'s UserKeyMapping), which the app's event
/// tap then turns into ⌃⌥⇧⌘. Mappings you already have (from `hidutil` or another tool) are kept, and a Caps Lock
/// mapping of yours comes back when the Hyper Key is turned off.
public enum QuicklinksHyperKeyMapping {
    /// HID usages (page 7, keyboard) as `hidutil` writes them.
    public static let capsLock: UInt64 = 0x7_0000_0039
    public static let f18: UInt64 = 0x7_0000_006D

    public struct Pair: Equatable, Sendable {
        public let source: UInt64
        public let destination: UInt64

        public init(source: UInt64, destination: UInt64) {
            self.source = source
            self.destination = destination
        }
    }

    public static let hyper = Pair(source: capsLock, destination: f18)

    /// The mappings in `hidutil property --get UserKeyMapping`'s output, each once, in order. The output lists every
    /// keyboard service with its value (an old-style plist array of dictionaries, or "(null)").
    public static func parse(_ output: String) -> [Pair] {
        var pairs: [Pair] = []
        var rest = Substring(output)
        while let open = rest.firstIndex(of: "{") {
            let body = rest[rest.index(after: open)...]
            let close = body.firstIndex(of: "}") ?? body.endIndex
            let block = body[..<close]
            if let source = number(after: "HIDKeyboardModifierMappingSrc", in: block),
               let destination = number(after: "HIDKeyboardModifierMappingDst", in: block) {
                let pair = Pair(source: source, destination: destination)
                if !pairs.contains(pair) { pairs.append(pair) }
            }
            rest = close < body.endIndex ? body[body.index(after: close)...] : ""
        }
        return pairs
    }

    /// The number after `key` and its `=` or `:` (decimal, or hex with 0x).
    private static func number(after key: String, in text: Substring) -> UInt64? {
        guard let range = text.range(of: key) else { return nil }
        let value = text[range.upperBound...].drop { " \t\"=:".contains($0) }
        if value.lowercased().hasPrefix("0x") {
            return UInt64(String(value.dropFirst(2).prefix { $0.isHexDigit }), radix: 16)
        }
        return UInt64(String(value.prefix { $0.isNumber }))
    }

    /// The mappings with Caps Lock → F18 in place of any other Caps Lock mapping, and that other mapping's
    /// destination (to restore later).
    public static func enabling(_ current: [Pair]) -> (mappings: [Pair], previousCapsLock: UInt64?) {
        let previous = current.first { $0.source == capsLock && $0.destination != f18 }?.destination
        return (current.filter { $0.source != capsLock } + [hyper], previous)
    }

    /// The mappings without Caps Lock → F18, and with Caps Lock's earlier mapping back if there was one.
    public static func disabling(_ current: [Pair], restoring previous: UInt64?) -> [Pair] {
        var mappings = current.filter { $0 != hyper }
        if let previous, !mappings.contains(where: { $0.source == capsLock }) {
            mappings.append(Pair(source: capsLock, destination: previous))
        }
        return mappings
    }

    /// What `hidutil property --set` takes: `{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":…,…}]}`.
    public static func json(_ mappings: [Pair]) -> String {
        let entries = mappings.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}"
        }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }
}

/// What the Hyper Key's event tap does with each key press: F18 (Caps Lock, remapped) is swallowed and only marks
/// the Hyper Key held; while it's held, every other key gets ⌃⌥⌘ (⇧) added. Letting it go soon after pressing it, with
/// no other key between, is a quick press.
public struct QuicklinksHyperKeyState: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Not the tap's business.
        case pass
        /// The Hyper Key itself: nobody else sees it.
        case swallow
        /// A key pressed with the Hyper Key held: add the modifiers.
        case addModifiers
        /// The Hyper Key went up after a short press on its own (swallowed too).
        case quickPress
    }

    /// kVK_F18.
    public static let f18KeyCode: Int64 = 79
    /// A press held longer than this isn't a quick press, even with no other key.
    public static let quickPressLimit: TimeInterval = 0.4

    public private(set) var isHeld = false
    private var pressedAt: TimeInterval = 0
    private var usedWhileHeld = false

    public init() {}

    /// One key down or up, at a time in seconds (the event's timestamp).
    public mutating func handle(keyCode: Int64, isDown: Bool, at time: TimeInterval) -> Decision {
        if keyCode == Self.f18KeyCode {
            if isDown {
                // Key repeat sends more downs while it's held.
                if !isHeld {
                    isHeld = true
                    usedWhileHeld = false
                    pressedAt = time
                }
                return .swallow
            }
            let quick = isHeld && !usedWhileHeld && time - pressedAt <= Self.quickPressLimit
            isHeld = false
            return quick ? .quickPress : .swallow
        }
        guard isHeld else { return .pass }
        usedWhileHeld = true
        return .addModifiers
    }

    /// The tap was switched off for a moment (macOS does that when a tap is slow): a release may have been missed.
    public mutating func reset() {
        isHeld = false
        usedWhileHeld = false
    }
}

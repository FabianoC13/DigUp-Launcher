import Foundation

/// What the system commands read back from the tools they run (`osascript`, `networksetup`, `defaults`): parsed here,
/// apart from the app, so the formats are tested.
public enum LauncherSystemOutput {
    /// The AppleScript error number at the end of `osascript`'s error ("… Not authorized to send Apple events to
    /// System Events. (-1743)" → -1743).
    public static func scriptErrorCode(_ stderr: String) -> Int? {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        return Int(text[text.index(after: open)..<text.index(before: text.endIndex)])
    }

    /// AppleScript's "not allowed to send Apple events" (Privacy & Security → Automation is off for that app).
    public static let notAuthorized = -1743
    /// No answer in time (macOS's "DigUp wants to control…" question was left open).
    public static let timedOut = -1712
    /// The user cancelled (a dialog's Cancel button).
    public static let userCancelled = -128

    /// The device of the Wi-Fi port in `networksetup -listallhardwareports` ("Hardware Port: Wi-Fi" / "Device: en0");
    /// older systems call the port AirPort.
    public static func wifiDevice(inHardwarePorts output: String) -> String? {
        var port: String?
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = value(of: "Hardware Port:", in: trimmed) {
                port = value
            } else if let device = value(of: "Device:", in: trimmed), let current = port {
                if current == "Wi-Fi" || current == "AirPort" || current == "WLAN" { return device }
                port = nil
            }
        }
        return nil
    }

    /// What follows `label` on a "Label: value" line; nil when the line doesn't start with it.
    private static func value(of label: String, in line: String) -> String? {
        guard line.hasPrefix(label) else { return nil }
        return line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
    }

    /// Whether Wi-Fi is on, from `networksetup -getairportpower <device>` ("Wi-Fi Power (en0): On"); nil when the
    /// output says something else (not a Wi-Fi interface, an error).
    public static func wifiPower(_ output: String) -> Bool? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.contains("Power"), let colon = line.lastIndex(of: ":") else { return nil }
        switch line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// A boolean preference as `defaults read` prints it ("1", "0", "YES", "true"…); nil for anything else (the key
    /// isn't set: `defaults` fails and prints nothing to stdout).
    public static func defaultsBool(_ output: String) -> Bool? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "yes", "true": return true
        case "0", "no", "false": return false
        default: return nil
        }
    }

    /// A numeric setting from `pmset -g`'s "Currently in use" list (" lowpowermode         0" → 0); nil when this Mac
    /// doesn't list it (no Low Power Mode before macOS 12, or on some desktops).
    public static func pmsetSetting(_ name: String, in output: String) -> Int? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(name) else { continue }
            let rest = trimmed.dropFirst(name.count)
            // "lowpowermode 0", not "lowpowermodeX 0".
            guard let first = rest.first, first == " " || first == "\t" else { continue }
            let value = rest.trimmingCharacters(in: .whitespaces).prefix { !$0.isWhitespace }
            if let number = Int(value) { return number }
        }
        return nil
    }

    /// "Safari, Mail and Notes", or "Safari, Mail, Notes and 4 more" past `limit` names.
    public static func list(_ names: [String], limit: Int = 6) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        if names.count > limit {
            return names.prefix(limit).joined(separator: ", ") + " and \(names.count - limit) more"
        }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

/// AppleScript's `get volume settings`, as `osascript` prints the record: "output volume:50, input volume:42, alert
/// volume:100, output muted:false". Volumes run 0…100; an output without a volume control (some HDMI and USB devices)
/// says "missing value".
public struct LauncherVolumeSettings: Equatable, Sendable {
    public var output: Int?
    public var input: Int?
    public var alert: Int?
    public var muted: Bool?

    public init(output: Int? = nil, input: Int? = nil, alert: Int? = nil, muted: Bool? = nil) {
        self.output = output
        self.input = input
        self.alert = alert
        self.muted = muted
    }

    /// Nil when the text isn't a volume settings record.
    public init?(_ text: String) {
        var fields: [String: String] = [:]
        for part in text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["output volume"] != nil || fields["output muted"] != nil else { return nil }
        // AppleScript prints whole volumes, but a real ("37.5") is read too.
        func volume(_ key: String) -> Int? { fields[key].flatMap(Double.init).map { Int($0.rounded()) } }
        output = volume("output volume")
        input = volume("input volume")
        alert = volume("alert volume")
        muted = fields["output muted"].flatMap { $0 == "true" ? true : $0 == "false" ? false : nil }
    }

    /// The output volume after a step up or down (`step` points), kept within 0…100.
    public static func stepped(_ volume: Int, by step: Int) -> Int {
        min(100, max(0, volume + step))
    }

    /// The level in a typed "set volume" request: "volume 30", "set volume to 30%", "vol 30 %", "volume 0"; nil when
    /// the text isn't one, or the level isn't within 0…100.
    public static func requestedLevel(_ text: String) -> Int? {
        var words = text.lowercased()
            .replacingOccurrences(of: "%", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard words.count >= 2, let level = Int(words.removeLast()), (0...100).contains(level) else { return nil }
        if words.first == "set" { words.removeFirst() }
        if words.last == "to" { words.removeLast() }
        guard words.count == 1, let word = words.first, word.count >= 3, "volume".hasPrefix(word) else { return nil }
        return level
    }
}

/// A mounted volume, as Eject All Disks sees it (`URLResourceValues` of `FileManager.mountedVolumeURLs`).
public struct LauncherVolumeInfo: Equatable, Sendable {
    public var name: String
    public var isRoot: Bool
    public var isEjectable: Bool
    public var isRemovable: Bool
    /// False for network shares; nil when the system didn't say.
    public var isLocal: Bool?
    /// False for external disks and disk images; nil when the system didn't say.
    public var isInternal: Bool?

    public init(name: String, isRoot: Bool = false, isEjectable: Bool = false, isRemovable: Bool = false,
                isLocal: Bool? = true, isInternal: Bool? = true) {
        self.name = name
        self.isRoot = isRoot
        self.isEjectable = isEjectable
        self.isRemovable = isRemovable
        self.isLocal = isLocal
        self.isInternal = isInternal
    }

    /// What Finder's eject button would offer: removable media, disk images, external disks and network shares, never
    /// the startup disk or another volume of an internal disk.
    public var shouldEject: Bool {
        if isRoot { return false }
        if isEjectable || isRemovable { return true }
        if isLocal == false { return true }
        return isInternal == false
    }
}

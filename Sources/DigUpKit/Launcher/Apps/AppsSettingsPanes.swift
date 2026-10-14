import Foundation

/// System Settings panes as launcher results: reading each pane's extension Info.plist (macOS 13+ builds Settings
/// from ExtensionKit extensions in /System/Library/ExtensionKit/Extensions), deciding which ones Settings shows on
/// this Mac, naming them, and the x-apple.systempreferences: links that open them.
public enum AppsSettingsPanes {
    /// The extension point of a pane of System Settings.
    public static let extensionPoint = "com.apple.Settings.extension.ui"
    public static let urlScheme = "x-apple.systempreferences:"

    /// A preference a representation's predicate reads (Game Controllers shows once a controller was used).
    public struct PreferenceValue: Equatable, Sendable {
        public let domain: String
        public let key: String
    }

    /// One way Settings can show a pane, picked by its predicate ("powersource.battery == YES" → "Battery").
    public struct Representation: Equatable, Sendable {
        public var predicate: String?
        public var hidden: Bool
        /// A key into the extension's Localizable strings ("BATTERY_PREF_TITLE"), or a plain name.
        public var sidebarName: String?
        /// The uniform type whose icon Settings' sidebar shows for it ("com.apple.graphic-icon.battery").
        public var iconType: String?
        public var preferences: [PreferenceValue]

        public init(predicate: String?, hidden: Bool, sidebarName: String? = nil, iconType: String? = nil,
                    preferences: [PreferenceValue] = []) {
            self.predicate = predicate
            self.hidden = hidden
            self.sidebarName = sidebarName
            self.iconType = iconType
            self.preferences = preferences
        }
    }

    /// What a pane's Info.plist says about it.
    public struct Info: Equatable, Sendable {
        public var bundleID: String
        /// Settings opens it from an x-apple.systempreferences: link.
        public var opensByURL: Bool
        public var representations: [Representation]
        /// Another name Settings shows it under ("Login Items & Extensions").
        public var alternateName: String?
        /// Its .searchTerms file (keywords Settings' own search uses), without the extension.
        public var searchTermsFile: String?
        public var displayName: String?
        public var name: String?
    }

    /// The pane described by an extension's Info.plist, or nil when the extension isn't a Settings pane.
    public static func info(fromInfoPlist plist: [String: Any]) -> Info? {
        guard let attributes = plist["EXAppExtensionAttributes"] as? [String: Any],
              attributes["EXExtensionPointIdentifier"] as? String == extensionPoint,
              let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }
        let settings = attributes["SettingsExtensionAttributes"] as? [String: Any] ?? [:]
        let representations = (settings["representations"] as? [[String: Any]] ?? []).map { entry in
            Representation(
                predicate: entry["predicate"] as? String,
                hidden: AppsCatalogRules.isFlagOn(entry["hidden"]),
                sidebarName: entry["sidebar-name"] as? String,
                iconType: entry["sidebar-iconUTTypeIdentifier"] as? String,
                preferences: (entry["values_from_preferences"] as? [[String: Any]] ?? []).compactMap { value in
                    guard let domain = value["domain"] as? String, let key = value["key"] as? String else { return nil }
                    return PreferenceValue(domain: domain, key: key)
                })
        }
        return Info(bundleID: bundleID,
                    opensByURL: AppsCatalogRules.isFlagOn(settings["allowsXAppleSystemPreferencesURLScheme"]),
                    representations: representations,
                    alternateName: settings["alt_name"] as? String,
                    searchTermsFile: settings["searchTermsFileName"] as? String,
                    displayName: plist["CFBundleDisplayName"] as? String,
                    name: plist["CFBundleName"] as? String)
    }

    /// The truth of a representation's predicate ("device.cddvd == YES", "showGCPrefsPane != YES") given what's known
    /// about this Mac; nil when it names something unknown or isn't a simple comparison.
    public static func evaluate(_ predicate: String, facts: [String: Bool]) -> Bool? {
        let parts = predicate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 3, parts[1] == "==" || parts[1] == "!=" else { return nil }
        let expected: Bool
        switch parts[2].uppercased() {
        case "YES", "TRUE", "1": expected = true
        case "NO", "FALSE", "0": expected = false
        default: return nil
        }
        guard let value = facts[parts[0]] else { return nil }
        return parts[1] == "==" ? value == expected : value != expected
    }

    /// Whether Settings shows the pane on this Mac, and the representation it shows it as (its sidebar name and
    /// icon). A pane without representations shows; one whose predicates can't be decided shows as its first visible
    /// one.
    public static func choose(_ representations: [Representation], facts: [String: Bool])
        -> (visible: Bool, representation: Representation?) {
        guard !representations.isEmpty else { return (true, nil) }
        var undecided: Representation?
        for representation in representations {
            guard let predicate = representation.predicate else {
                if !representation.hidden, undecided == nil { undecided = representation }
                continue
            }
            switch evaluate(predicate, facts: facts) {
            case true?: return (!representation.hidden, representation)
            case false?: continue
            case nil: if !representation.hidden, undecided == nil { undecided = representation }
            }
        }
        if let undecided { return (true, undecided) }
        // Every predicate decided, none true: Settings hides it only if one of them said so.
        return (!representations.contains { $0.hidden }, nil)
    }

    /// The name a pane goes by, best first: its sidebar name, its localized display name, the name this table knows,
    /// then the Info.plist's names unless they're internal ("WiFiSettings"), then its file name tidied up.
    public static func displayName(sidebarName: String?, localizedDisplayName: String?, knownName: String?,
                                   infoDisplayName: String?, infoName: String?, fileName: String) -> String {
        for candidate in [sidebarName, localizedDisplayName, knownName] {
            if let candidate = tidy(candidate) { return candidate }
        }
        for candidate in [infoDisplayName, infoName] {
            if let candidate = tidy(candidate), !looksInternal(candidate) { return candidate }
        }
        var stem = (fileName as NSString).deletingPathExtension
        for suffix in ["SettingsExtension", "Settings Extension", "Extension", "Settings", "Ext", "Preferences"]
        where stem.hasSuffix(suffix) && stem.count > suffix.count {
            stem = String(stem.dropLast(suffix.count))
        }
        return FuzzyMatch.words(stem, splittingCamelCase: true).joined(separator: " ")
    }

    private static func tidy(_ name: String?) -> String? {
        guard let name = name?.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        // An untranslated key ("BATTERY_PREF_TITLE") isn't a name.
        if name.contains("_"), name == name.uppercased() { return nil }
        return name
    }

    /// A developer's name for the bundle rather than what Settings shows: "DisplaysExt", "WiFiSettings",
    /// "DateAndTime Extension", "CoverageSettingPane_macOS".
    public static func looksInternal(_ name: String) -> Bool {
        if name.contains("_") { return true }
        for marker in ["Extension", "Settings", "Ext", "Pref", "Pane"] where name.contains(marker) { return true }
        // Camel case run together ("LockScreen", "UsersGroups").
        let characters = Array(name)
        for index in characters.indices.dropFirst() where characters[index].isUppercase
            && characters[index - 1].isLowercase {
            return true
        }
        return false
    }

    /// The words Settings' own search finds a pane by, from its .searchTerms file: each entry's title ("Output
    /// balance") and index words ("headphones, speakers…"), each once.
    public static func searchTerms(fromPlist plist: [String: Any], limit: Int = 60) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        func add(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = FuzzyMatch.normalize(trimmed)
            guard !key.isEmpty, terms.count < limit, seen.insert(key).inserted else { return }
            terms.append(trimmed)
        }
        for key in plist.keys.sorted() {
            guard let group = plist[key] as? [String: Any],
                  let strings = group["localizableStrings"] as? [[String: Any]] else { continue }
            for entry in strings {
                if let title = entry["title"] as? String { add(title) }
                if let index = entry["index"] as? String {
                    for word in index.split(separator: ",") { add(String(word)) }
                }
            }
        }
        return terms
    }

    /// How well `query` matches a pane: its name and keywords as usual, and its search terms only when a word of
    /// one starts with what's typed and at least three characters are (they're many, and loose or short matches in
    /// them would be noise: "lo" is in "louder" and "lower").
    public static func score(_ query: String, name: String, keywords: [String], searchTerms: [String]) -> Double? {
        var best = FuzzyMatch.best(query, name: name, keywords: keywords)
        guard FuzzyMatch.normalize(query).count >= 3 else { return best }
        for term in searchTerms {
            guard let score = FuzzyMatch.score(query, term), score >= 0.7 else { continue }
            let weighted = score * 0.8
            if weighted > (best ?? 0) { best = weighted }
        }
        return best
    }

    /// The link that opens a pane, at an anchor if given ("Privacy_Accessibility").
    public static func url(for bundleID: String, anchor: String? = nil) -> String {
        urlScheme + bundleID + (anchor.map { "?" + $0 } ?? "")
    }

    /// What this table knows about a pane that its Info.plist doesn't say well: the name Settings shows (when the
    /// bundle's own is internal), words people search it by, and the system's graphic icon for it
    /// ("com.apple.graphic-icon.<icon>", the pictures Settings' sidebar uses).
    public struct KnownPane: Sendable {
        public let name: String?
        public let keywords: [String]
        public let icon: String?

        public init(_ name: String?, _ keywords: [String], icon: String? = nil) {
            self.name = name
            self.keywords = keywords
            self.icon = icon
        }

        /// The uniform type whose icon is the pane's picture.
        public var iconType: String? { icon.map { "com.apple.graphic-icon." + $0 } }
    }

    /// Panes whose names on disk aren't what Settings shows, words people search them by, and their icons.
    public static let known: [String: KnownPane] = [
        "com.apple.wifi-settings-extension": KnownPane("Wi-Fi", ["wifi", "wireless", "internet", "network", "wlan"],
                                                       icon: "wifi"),
        "com.apple.BluetoothSettings": KnownPane("Bluetooth", ["wireless", "devices", "airpods", "pair"],
                                                 icon: "bluetooth"),
        "com.apple.Network-Settings.extension": KnownPane("Network", ["internet", "ethernet", "proxy", "dns",
                                                                      "ip address", "firewall"], icon: "local-network"),
        "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension": KnownPane("VPN", ["tunnel"], icon: "vpn"),
        "com.apple.Sound-Settings.extension": KnownPane("Sound", ["volume", "audio", "speakers", "microphone",
                                                                  "output", "input"], icon: "sound"),
        "com.apple.Displays-Settings.extension": KnownPane("Displays", ["monitor", "screen", "resolution", "brightness",
                                                                        "night shift"], icon: "display"),
        "com.apple.Keyboard-Settings.extension": KnownPane("Keyboard", ["shortcuts", "input sources", "key repeat",
                                                                        "dictation"], icon: "keyboard"),
        "com.apple.Trackpad-Settings.extension": KnownPane("Trackpad", ["gestures", "tap to click", "scrolling"],
                                                           icon: "trackpad-and-mouse"),
        "com.apple.Mouse-Settings.extension": KnownPane("Mouse", ["scrolling", "tracking speed"],
                                                        icon: "trackpad-and-mouse"),
        "com.apple.Battery-Settings.extension": KnownPane(nil, ["battery", "energy", "power", "low power mode"],
                                                          icon: "battery"),
        "com.apple.settings.PrivacySecurity.extension": KnownPane("Privacy & Security", ["privacy", "security",
                                                                                        "permissions", "filevault"],
                                                                  icon: "privacy"),
        "com.apple.Accessibility-Settings.extension": KnownPane("Accessibility", ["voiceover", "zoom", "a11y"],
                                                                icon: "accessibility"),
        "com.apple.Appearance-Settings.extension": KnownPane("Appearance", ["dark mode", "light mode", "accent color",
                                                                            "theme"], icon: "dark-mode"),
        "com.apple.Desktop-Settings.extension": KnownPane("Desktop & Dock", ["dock", "mission control",
                                                                             "stage manager", "hot corners",
                                                                             "windows"], icon: "desktop"),
        "com.apple.ControlCenter-Settings.extension": KnownPane("Menu Bar", ["control center", "menu bar"],
                                                                icon: "control-center"),
        "com.apple.Notifications-Settings.extension": KnownPane("Notifications", ["alerts", "banners"],
                                                                icon: "notifications"),
        "com.apple.Focus-Settings.extension": KnownPane("Focus", ["do not disturb", "dnd"], icon: "focus"),
        "com.apple.Screen-Time-Settings.extension": KnownPane("Screen Time", ["parental controls", "limits"],
                                                              icon: "screen-time"),
        "com.apple.systempreferences.GeneralSettings": KnownPane("General", [], icon: "gear"),
        "com.apple.SystemProfiler.AboutExtension": KnownPane("About", ["about this mac", "serial number", "model"],
                                                             icon: "about-current-device"),
        "com.apple.Software-Update-Settings.extension": KnownPane("Software Update", ["update", "upgrade", "macos"],
                                                                  icon: "software-update"),
        "com.apple.settings.Storage": KnownPane("Storage", ["disk space", "free space"], icon: "internal-drive"),
        "com.apple.AirDrop-Handoff-Settings.extension": KnownPane("AirDrop & Handoff", ["airdrop", "handoff",
                                                                                        "continuity",
                                                                                        "airplay receiver"],
                                                                  icon: "airdrop"),
        "com.apple.LoginItems-Settings.extension": KnownPane("Login Items", ["startup", "launch at login",
                                                                             "extensions"], icon: "app-installation"),
        "com.apple.Localization-Settings.extension": KnownPane("Language & Region", ["language", "region", "locale",
                                                                                     "date format"], icon: "language"),
        "com.apple.Date-Time-Settings.extension": KnownPane("Date & Time", ["clock", "time zone"],
                                                            icon: "date-and-time"),
        "com.apple.Sharing-Settings.extension": KnownPane("Sharing", ["file sharing", "screen sharing", "remote login",
                                                                     "ssh", "computer name"], icon: "file-sharing"),
        "com.apple.Time-Machine-Settings.extension": KnownPane("Time Machine", ["backup"]),
        "com.apple.Transfer-Reset-Settings.extension": KnownPane("Transfer or Reset", ["erase", "factory reset"]),
        "com.apple.Startup-Disk-Settings.extension": KnownPane("Startup Disk", ["boot"], icon: "internal-drive"),
        "com.apple.Wallpaper-Settings.extension": KnownPane("Wallpaper", ["background", "desktop picture",
                                                                          "screen saver"], icon: "wallpaper"),
        "com.apple.Lock-Screen-Settings.extension": KnownPane("Lock Screen", ["screen saver", "sleep", "password"],
                                                              icon: "auto-lock"),
        "com.apple.Touch-ID-Settings.extension": KnownPane(nil, ["touch id", "fingerprint", "password",
                                                                 "login password"], icon: "touch-id"),
        "com.apple.Users-Groups-Settings.extension": KnownPane("Users & Groups", ["accounts", "users", "guest"],
                                                               icon: "group"),
        "com.apple.Internet-Accounts-Settings.extension": KnownPane("Internet Accounts", ["email accounts", "google",
                                                                                          "exchange"]),
        "com.apple.systempreferences.AppleIDSettings": KnownPane("Apple Account", ["apple id", "icloud"]),
        "com.apple.Family-Settings.extension": KnownPane("Family", ["family sharing"]),
        "com.apple.Print-Scan-Settings.extension": KnownPane("Printers & Scanners", ["printer", "scanner", "print"],
                                                             icon: "printer-sharing"),
        "com.apple.Siri-Settings.extension": KnownPane(nil, ["siri", "apple intelligence", "voice"]),
        "com.apple.Spotlight-Settings.extension": KnownPane("Spotlight", ["search", "indexing"]),
        "com.apple.Game-Center-Settings.extension": KnownPane("Game Center", ["games"]),
        "com.apple.Game-Controller-Settings.extension": KnownPane("Game Controllers", ["gamepad", "controller"]),
        "com.apple.WalletSettingsExtension": KnownPane("Wallet & Apple Pay", ["apple pay", "cards"]),
        "com.apple.Profiles-Settings.extension": KnownPane("Device Management", ["profiles", "mdm"],
                                                           icon: "device-management"),
        "com.apple.HeadphoneSettings": KnownPane("Headphones", ["airpods"], icon: "accessories"),
        "com.apple.Coverage-Settings.extension": KnownPane("AppleCare & Warranty", ["warranty", "applecare"],
                                                           icon: "applecare"),
        "com.apple.SecurityImprovements-Settings.extension": KnownPane("Background Security Improvements",
                                                                       ["security updates", "rapid security response"],
                                                                       icon: "background-security-improvements"),
        "com.apple.CD-DVD-Settings.extension": KnownPane("CDs & DVDs", ["optical drive"], icon: "external-drive"),
    ]

    /// Panes Settings keeps out of its sidebar unless something special is set up (a school's Classroom, follow-up
    /// requests), or that only another pane opens.
    public static let hiddenPanes: Set<String> = [
        "com.apple.Classroom-Settings.extension", "com.apple.FollowUpSettings.FollowUpSettingsExtension",
        "com.apple.Home.PrivacySettingsExtension",
    ]

    /// The pane every privacy anchor opens in (its pre-Ventura id, which current Settings still answers to).
    public static let privacyPane = "com.apple.preference.security"

    /// The permission lists of Privacy & Security, each its own result ("Full Disk Access") since that's where
    /// people go most: anchor, title, keywords.
    public static let privacyAnchors: [(anchor: String, title: String, keywords: [String])] = [
        ("Privacy_Accessibility", "Accessibility Permissions", ["privacy accessibility", "control your computer"]),
        ("Privacy_AllFiles", "Full Disk Access", ["privacy files", "disk access"]),
        ("Privacy_FilesAndFolders", "Files & Folders Permissions", ["privacy files", "documents", "downloads"]),
        ("Privacy_ScreenCapture", "Screen & System Audio Recording", ["screen recording", "privacy screen"]),
        ("Privacy_Microphone", "Microphone Permissions", ["privacy microphone", "mic"]),
        ("Privacy_Camera", "Camera Permissions", ["privacy camera", "webcam"]),
        ("Privacy_LocationServices", "Location Services", ["privacy location", "gps"]),
        ("Privacy_Automation", "Automation Permissions", ["privacy automation", "apple events", "applescript"]),
        ("Privacy_ListenEvent", "Input Monitoring", ["privacy keyboard", "keylogger"]),
        ("Privacy_AppBundles", "App Management", ["privacy app management", "update apps"]),
        ("Privacy_DevTools", "Developer Tools", ["privacy developer tools"]),
        ("Privacy_Calendars", "Calendars Permissions", ["privacy calendar"]),
        ("Privacy_Contacts", "Contacts Permissions", ["privacy contacts"]),
        ("Privacy_Reminders", "Reminders Permissions", ["privacy reminders"]),
        ("Privacy_Photos", "Photos Permissions", ["privacy photos"]),
        ("Privacy_Bluetooth", "Bluetooth Permissions", ["privacy bluetooth"]),
    ]

    /// The panes to offer when the extensions can't be read (an older or locked-down system): the common ones.
    public static var fallbackPanes: [(bundleID: String, name: String, keywords: [String])] {
        known.compactMap { id, entry in entry.name.map { (id, $0, entry.keywords) } }
            .filter { !hiddenPanes.contains($0.0) }
            .sorted { $0.name < $1.name }
    }
}

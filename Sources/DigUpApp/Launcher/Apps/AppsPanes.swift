import AppKit
import CoreFoundation
import DigUpKit
import IOKit.ps
import LocalAuthentication
import UniformTypeIdentifiers

/// One pane of System Settings: what it's called on this Mac, what it's searched by, and the link that opens it.
nonisolated struct AppsPaneEntry: Sendable {
    /// "pane:<bundle id>", or "pane:privacy:<anchor>" for a permission list of Privacy & Security.
    let id: String
    let name: String
    /// Where it is in Settings ("Privacy & Security" for a permission list), nil for a pane of its own.
    let parent: String?
    let keywords: [String]
    /// The words Settings' own search finds it by.
    let searchTerms: [String]
    /// "x-apple.systempreferences:com.apple.wifi-settings-extension".
    let link: String
    /// The system's graphic icon for it ("com.apple.graphic-icon.wifi"), when known.
    let iconType: String?
    /// The extension bundle and the name of its icon in its asset catalog, when it ships one.
    let bundlePath: String?
    let iconName: String?
}

/// The panes of System Settings on this Mac, read from its ExtensionKit extensions off the main thread, plus the
/// permission lists of Privacy & Security. Falls back to a table of the common panes when the extensions can't be
/// read.
final class AppsPaneCatalog {
    private(set) var entries: [AppsPaneEntry] = []
    private var icons: [String: NSImage] = [:]
    private var loading = false

    nonisolated static let extensionsFolder = "/System/Library/ExtensionKit/Extensions"
    static let settingsAppID = "com.apple.systempreferences"

    func load() {
        guard !loading else { return }
        loading = true
        let started = Date()
        Task {
            let found = await Task.detached(priority: .utility) { AppsPaneReader.read() }.value
            entries = found
            icons = [:]
            loading = false
            log("apps: \(found.count) Settings panes in \(ms(since: started))")
        }
    }

    func entry(id: String) -> AppsPaneEntry? { entries.first { $0.id == id } }

    /// The pane's picture: the system's graphic icon for it, its own, or System Settings' icon.
    func icon(for entry: AppsPaneEntry) -> LauncherIcon {
        if let cached = icons[entry.id] { return .image(cached) }
        var image: NSImage?
        if let type = entry.iconType.flatMap({ UTType($0) }), type.isDeclared {
            image = NSWorkspace.shared.icon(for: type)
        }
        if image == nil, let path = entry.bundlePath, let name = entry.iconName {
            image = Bundle(path: path)?.image(forResource: name)
        }
        if image == nil, let settings = Self.settingsAppURL {
            image = NSWorkspace.shared.icon(forFile: settings.path)
        }
        guard let image else { return .symbol("gearshape") }
        icons[entry.id] = image
        return .image(image)
    }

    static var settingsAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: settingsAppID)
    }
}

/// Reads the Settings extensions' Info.plists and resources: no main-thread state, so it runs in a detached task.
nonisolated enum AppsPaneReader {
    static func read() -> [AppsPaneEntry] {
        let folder = AppsPaneCatalog.extensionsFolder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        var infos: [(info: AppsSettingsPanes.Info, path: String, bundle: Bundle?, plist: [String: Any])] = []
        for name in names.sorted() where name.hasSuffix(".appex") {
            let path = folder + "/" + name
            guard let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
                  let info = AppsSettingsPanes.info(fromInfoPlist: plist) else { continue }
            infos.append((info, path, Bundle(path: path), plist))
        }
        let facts = self.facts(for: infos.flatMap { $0.info.representations })
        var entries: [AppsPaneEntry] = []
        var seen = Set<String>()
        for (info, path, bundle, plist) in infos {
            guard info.opensByURL, !AppsSettingsPanes.hiddenPanes.contains(info.bundleID),
                  seen.insert(info.bundleID).inserted else { continue }
            let choice = AppsSettingsPanes.choose(info.representations, facts: facts)
            guard choice.visible else { continue }
            let known = AppsSettingsPanes.known[info.bundleID]
            let sidebarName = choice.representation?.sidebarName.map {
                bundle?.localizedString(forKey: $0, value: $0, table: nil) ?? $0
            }
            let name = AppsSettingsPanes.displayName(
                sidebarName: sidebarName,
                localizedDisplayName: bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
                knownName: known?.name, infoDisplayName: info.displayName, infoName: info.name,
                fileName: (path as NSString).lastPathComponent)
            var keywords = known?.keywords ?? []
            if let alternate = info.alternateName { keywords.append(alternate) }
            if name.contains("&") {
                // "Touch ID & Password" is also found as "touch id and password".
                keywords.append(name.replacingOccurrences(of: "&", with: "and"))
            }
            let attributes = (plist["EXAppExtensionAttributes"] as? [String: Any])?["SettingsExtensionAttributes"]
                as? [String: Any]
            entries.append(AppsPaneEntry(
                id: "pane:" + info.bundleID, name: name, parent: nil, keywords: keywords,
                searchTerms: searchTerms(info, bundle: bundle),
                link: AppsSettingsPanes.url(for: info.bundleID),
                iconType: choice.representation?.iconType ?? known?.iconType,
                bundlePath: path, iconName: attributes?["IconName"] as? String))
        }
        if entries.isEmpty {
            log("apps: no Settings extensions readable, using the built-in list of panes")
            entries = AppsSettingsPanes.fallbackPanes.map { pane in
                AppsPaneEntry(id: "pane:" + pane.bundleID, name: pane.name, parent: nil, keywords: pane.keywords,
                              searchTerms: [], link: AppsSettingsPanes.url(for: pane.bundleID),
                              iconType: AppsSettingsPanes.known[pane.bundleID]?.iconType, bundlePath: nil,
                              iconName: nil)
            }
        }
        let privacyName = entries.first { $0.id == "pane:com.apple.settings.PrivacySecurity.extension" }?.name
            ?? "Privacy & Security"
        for anchor in AppsSettingsPanes.privacyAnchors {
            entries.append(AppsPaneEntry(
                id: "pane:privacy:" + anchor.anchor, name: anchor.title, parent: privacyName,
                keywords: anchor.keywords, searchTerms: [],
                link: AppsSettingsPanes.url(for: AppsSettingsPanes.privacyPane, anchor: anchor.anchor),
                iconType: "com.apple.graphic-icon.privacy", bundlePath: nil, iconName: nil))
        }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Settings' own search words for a pane, in the user's language.
    static func searchTerms(_ info: AppsSettingsPanes.Info, bundle: Bundle?) -> [String] {
        guard let file = info.searchTermsFile,
              let url = bundle?.url(forResource: file, withExtension: "searchTerms"),
              let plist = NSDictionary(contentsOf: url) as? [String: Any] else { return [] }
        return AppsSettingsPanes.searchTerms(fromPlist: plist)
    }

    /// What the panes' predicates ask about this Mac: a battery, Touch ID, a trackpad, whether the user is a guest,
    /// and the preferences some panes read ("showGCPrefsPane"). Unknown facts are left out, so their panes show.
    static func facts(for representations: [AppsSettingsPanes.Representation]) -> [String: Bool] {
        var facts: [String: Bool] = [:]
        let battery = hasBattery()
        facts["powersource.battery"] = battery
        // Every Mac laptop has a trackpad; a desktop may have a Magic Trackpad, which isn't known here.
        if battery { facts["device.trackpad"] = true }
        // No Mac has had a built-in optical drive since 2012.
        facts["device.cddvd"] = false
        facts["user.isguest"] = NSUserName() == "Guest"
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        facts["device.touchID"] = context.biometryType == .touchID
        for representation in representations {
            for preference in representation.preferences {
                let value = CFPreferencesCopyAppValue(preference.key as CFString, preference.domain as CFString)
                facts[preference.key] = AppsCatalogRules.isFlagOn(value)
            }
        }
        return facts
    }

    /// An internal battery is among the power sources (a MacBook).
    static func hasBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any] else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}

/// "pane": the panes of System Settings, and the permission lists of Privacy & Security.
final class AppsPanesProvider: LauncherProvider {
    let id = "pane"

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        let catalog = AppsFeature.panes
        var items: [LauncherItem] = []
        for entry in catalog.entries {
            guard let score = AppsSettingsPanes.score(query.text, name: entry.name, keywords: entry.keywords,
                                                      searchTerms: entry.searchTerms) else { continue }
            // An app of the same name comes first ("Passwords" the app, not the pane).
            items.append(Self.item(entry, score: score * 0.97))
        }
        return items
    }

    func item(id: String) async -> LauncherItem? {
        AppsFeature.panes.entry(id: id).map { Self.item($0, score: 0.5) }
    }

    static func item(_ entry: AppsPaneEntry, score: Double) -> LauncherItem {
        let link = entry.link
        var metadata: [(label: String, value: String)] = [("Opens", entry.parent.map { "System Settings → \($0)" }
            ?? "System Settings")]
        if !entry.keywords.isEmpty { metadata.append(("Keywords", entry.keywords.joined(separator: ", "))) }
        return LauncherItem(
            id: entry.id, title: entry.name, subtitle: entry.parent ?? "System Settings",
            icon: AppsFeature.panes.icon(for: entry), accessory: "System Settings", score: score,
            actions: [
                LauncherAction(id: "open", title: "Open in System Settings", symbol: "gearshape") { context in
                    guard let url = URL(string: link) else { return }
                    if !NSWorkspace.shared.open(url) {
                        AppsFeature.report("Couldn't open System Settings.", context: context)
                    }
                },
                LauncherAction(id: "copy-link", title: "Copy Link", symbol: "link", shortcut: .copyShift) { context in
                    context.copy(link)
                },
            ],
            metadata: metadata)
    }
}

import AppKit
import DigUpKit
import Observation

/// What a focus session blocks, kept between sessions.
struct FocusBlockList: Codable, Equatable {
    /// Bundle ids of the apps hidden (or quit) while a session runs.
    var apps: [String] = []
    /// Bare domains ("youtube.com"); their subdomains are blocked too.
    var domains: [String] = []
    /// Quit blocked apps instead of hiding them.
    var quitApps = false

    /// Offered in Settings, off until you turn them on.
    static let appPresets: [(bundleID: String, name: String)] = [
        ("com.apple.MobileSMS", "Messages"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
        ("com.apple.mail", "Mail"),
    ]
    static let domainPresets = ["youtube.com", "x.com", "twitter.com", "reddit.com", "instagram.com", "facebook.com",
                                "tiktok.com", "news.ycombinator.com"]
}

/// A running focus session, saved so it survives DigUp quitting.
struct FocusSessionState: Codable, Equatable {
    var goal: String
    var timer: FocusTimer
    /// Tabs showing the block page, per browser bundle id: token → the address the tab was on (given back at the end).
    var blockedTabs: [String: [String: String]] = [:]
    /// How many times an app or a website was blocked.
    var blocks = 0
}

/// Focus sessions: a timer in the menu bar, blocked apps hidden (or quit) as they come to the front, and blocked
/// websites replaced by a block page in the front browser tab (checked every 2 seconds through AppleScript).
@Observable
final class FocusController {
    static let shared = FocusController()

    private(set) var blockList = FocusBlockList()
    var session: FocusSessionState?
    weak var launcher: Launcher?

    @ObservationIgnored var statusItem: NSStatusItem?
    @ObservationIgnored var statusLine: NSMenuItem?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Browsers that refused DigUp's AppleScript this session (told once).
    @ObservationIgnored var refusedBrowsers: Set<String> = []
    @ObservationIgnored private var lastNotice: [String: Date] = [:]

    static var folder: URL { ProductivityFiles.folder("Focus") }
    private static var blockListFile: URL { folder.appendingPathComponent("blocklist.json") }
    private static var sessionFile: URL { folder.appendingPathComponent("session.json") }
    static var blockPage: URL { folder.appendingPathComponent(FocusBrowser.blockPageName) }

    var isActive: Bool { session != nil }
    var isPaused: Bool { session?.timer.isPaused == true }

    func start() {
        blockList = ProductivityFiles.load(FocusBlockList.self, from: Self.blockListFile) ?? FocusBlockList()
        guard let saved = ProductivityFiles.load(FocusSessionState.self, from: Self.sessionFile) else { return }
        session = saved
        if saved.timer.isFinished(at: Date()) {
            complete(timeUp: true)   // it ended while DigUp wasn't running
        } else {
            log("focus: resumed a session")
            activate()
        }
    }

    // MARK: Session

    /// Starts a session (ending the one running, if any).
    func begin(goal: String, duration: TimeInterval?) {
        if session != nil { end(summary: false) }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        session = FocusSessionState(goal: goal, timer: FocusTimer(started: Date(), duration: duration))
        saveSession()
        writeBlockPage(goal: goal)
        activate()
        for app in NSWorkspace.shared.runningApplications { block(app, notify: false) }
        let length = duration.map { FocusDuration.describe($0) } ?? "until you stop it"
        ProductivityHUD.show(goal.isEmpty ? "Focus: \(length)" : "Focus on \(goal): \(length)", symbol: "target")
        log("focus: started (\(duration.map { "\(Int($0 / 60)) min" } ?? "no end"))")
    }

    func pause() {
        guard var current = session, !current.timer.isPaused else { return }
        current.timer.pause(at: Date())
        session = current
        saveSession()
        rebuildMenu()
        tick()
    }

    func resume() {
        guard var current = session, current.timer.isPaused else { return }
        current.timer.resume(at: Date())
        session = current
        saveSession()
        rebuildMenu()
        tick()
        for app in NSWorkspace.shared.runningApplications { block(app, notify: false) }
    }

    func extend(by seconds: TimeInterval) {
        guard var current = session, current.timer.duration != nil else { return }
        current.timer.extend(by: seconds)
        session = current
        saveSession()
        tick()
    }

    /// Ends the session with a summary: `timeUp` when its time ran out, else you completed it.
    func complete(timeUp: Bool = false) {
        guard session != nil else { return }
        if timeUp { NSSound(named: "Glass")?.play() }
        end(summary: true)
    }

    private func end(summary: Bool) {
        guard let finished = session else { return }
        session = nil
        deactivate()
        try? FileManager.default.removeItem(at: Self.sessionFile)
        restoreTabs(finished.blockedTabs)
        guard summary else { return }
        let focused = FocusDuration.describe(max(60, finished.timer.elapsed(at: Date())))
        var text = finished.goal.isEmpty ? "Focus session complete: \(focused)" : "Done: \(focused) on \(finished.goal)"
        if finished.blocks > 0 { text += finished.blocks == 1 ? " · 1 distraction blocked" : " · \(finished.blocks) distractions blocked" }
        ProductivityHUD.show(text, symbol: "checkmark.circle", seconds: 5)
        log("focus: session ended")
    }

    // MARK: Block list

    func setApp(_ bundleID: String, blocked: Bool) {
        blockList.apps.removeAll { $0 == bundleID }
        if blocked { blockList.apps.append(bundleID) }
        saveBlockList()
        if blocked, let session, !session.timer.isPaused {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { block(app, notify: false) }
        }
    }

    func setDomain(_ domain: String, blocked: Bool) {
        blockList.domains.removeAll { $0 == domain }
        if blocked { blockList.domains.append(domain) }
        saveBlockList()
    }

    func setQuitApps(_ quit: Bool) {
        blockList.quitApps = quit
        saveBlockList()
    }

    private func saveBlockList() {
        ProductivityFiles.save(blockList, to: Self.blockListFile)
    }

    func saveSession() {
        if let session { ProductivityFiles.save(session, to: Self.sessionFile) }
    }

    // MARK: Running

    private func activate() {
        installStatusItem()
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                await self.checkFrontBrowser()
            }
        }
        if observers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    MainActor.assumeIsolated {
                        if let app { self?.block(app, notify: true) }
                    }
                })
            }
        }
    }

    private func deactivate() {
        tickTask?.cancel()
        tickTask = nil
        pollTask?.cancel()
        pollTask = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        statusLine = nil
        refusedBrowsers = []
        lastNotice = [:]
    }

    private func tick() {
        guard let session else { return }
        let now = Date()
        if session.timer.isFinished(at: now) {
            complete(timeUp: true)
            return
        }
        let shown = session.timer.remaining(at: now) ?? session.timer.elapsed(at: now)
        let clock = FocusDuration.clock(shown)
        statusItem?.button?.title = session.timer.isPaused ? "◎ ‖ \(clock)" : "◎ \(clock)"
        let state = session.timer.remaining(at: now) == nil ? "\(clock) focused" : "\(clock) left"
        statusLine?.title = session.timer.isPaused ? "Paused · \(state)" : state
    }

    /// Hides (or quits) an app on the block list while a session runs and isn't paused.
    private func block(_ app: NSRunningApplication, notify: Bool) {
        guard let session, !session.timer.isPaused, let bundleID = app.bundleIdentifier,
              blockList.apps.contains(bundleID), !app.isTerminated else { return }
        if blockList.quitApps { app.terminate() } else { app.hide() }
        count(block: bundleID)
        if notify { notice(bundleID, "\(app.localizedName ?? "That app") is blocked while you focus") }
        // An app that's still launching can ignore the first hide.
        guard !blockList.quitApps else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.session?.timer.isPaused == false, app.isActive, !app.isHidden else { return }
            app.hide()
        }
    }

    private func count(block key: String) {
        // A burst of activations of one app counts once.
        if let last = lastNotice["count:" + key], Date().timeIntervalSince(last) < 5 { return }
        lastNotice["count:" + key] = Date()
        session?.blocks += 1
        saveSession()
    }

    private func notice(_ key: String, _ text: String) {
        if let last = lastNotice[key], Date().timeIntervalSince(last) < 4 { return }
        lastNotice[key] = Date()
        ProductivityHUD.show(text, symbol: "hand.raised")
    }
}

import AppKit
import DigUpKit
import SwiftUI

/// Focus: sessions that block distracting apps and websites.
enum FocusFeature: LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [FocusProvider()]
    }

    static func start(_ launcher: Launcher) {
        FocusController.shared.launcher = launcher
        FocusController.shared.start()
    }

    static var settingsTitle: String? { "Focus" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(FocusSettingsView(focus: .shared))
    }
}

/// Root search: Start Focus Session, and Pause, Resume and Complete while a session makes them useful.
final class FocusProvider: LauncherProvider {
    let id = "focus"

    private enum Command: String, CaseIterable {
        case start, pause, resume, complete, edit

        var title: String {
            switch self {
            case .start: "Start Focus Session"
            case .pause: "Pause Focus Session"
            case .resume: "Resume Focus Session"
            case .complete: "Complete Focus Session"
            case .edit: "Edit Focus Block List"
            }
        }

        var keywords: [String] {
            switch self {
            case .start: ["focus", "deep work", "pomodoro", "block distractions"]
            case .pause: ["focus", "break"]
            case .resume: ["focus", "continue"]
            case .complete: ["focus", "stop focus", "end focus"]
            case .edit: ["focus", "blocked apps", "blocked websites", "distractions"]
            }
        }

        var symbol: String {
            switch self {
            case .start: "target"
            case .pause: "pause.circle"
            case .resume: "play.circle"
            case .complete: "checkmark.circle"
            case .edit: "slider.horizontal.3"
            }
        }

        /// Pause, Resume and Complete only show when they'd do something.
        var isRelevant: Bool {
            let focus = FocusController.shared
            switch self {
            case .start, .edit: return true
            case .pause: return focus.isActive && !focus.isPaused
            case .resume: return focus.isPaused
            case .complete: return focus.isActive
            }
        }
    }

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        guard !query.isEmpty else { return [] }
        return Command.allCases.compactMap { command in
            guard command.isRelevant, let score = query.match(command.title, keywords: command.keywords) else {
                return nil
            }
            var item = makeItem(command)
            item.score = score
            return item
        }
    }

    func item(id: String) async -> LauncherItem? {
        guard let command = Command(rawValue: String(id.dropFirst(self.id.count + 1))), command.isRelevant else {
            return nil
        }
        return makeItem(command)
    }

    private func makeItem(_ command: Command) -> LauncherItem {
        let focus = FocusController.shared
        let action: LauncherAction
        var subtitle: String?
        switch command {
        case .start:
            if let session = focus.session {
                subtitle = "Running: " + (session.goal.isEmpty ? "a session" : session.goal) + " (a new one ends it)"
            } else {
                subtitle = Self.blockSummary(focus.blockList)
            }
            action = LauncherAction(id: "start", title: "Start Focus Session", symbol: "target",
                                    keepsPanelOpen: true) { context in
                context.push(FocusStartMode())
            }
        case .pause:
            subtitle = focus.session.map { $0.goal.isEmpty ? "Focus session" : $0.goal }
            action = LauncherAction(id: "pause", title: "Pause", symbol: "pause") { _ in
                focus.pause()
                ProductivityHUD.show("Focus paused: nothing is blocked", symbol: "pause.circle")
            }
        case .resume:
            subtitle = focus.session.map { $0.goal.isEmpty ? "Focus session" : $0.goal }
            action = LauncherAction(id: "resume", title: "Resume", symbol: "play") { _ in
                focus.resume()
                ProductivityHUD.show("Focus resumed", symbol: "play.circle")
            }
        case .complete:
            subtitle = focus.session.map { $0.goal.isEmpty ? "Focus session" : $0.goal }
            action = LauncherAction(id: "complete", title: "Complete", symbol: "checkmark") { _ in
                if focus.isActive { focus.complete() } else { ProductivityHUD.show("No focus session", symbol: "target") }
            }
        case .edit:
            subtitle = Self.blockSummary(focus.blockList)
            action = LauncherAction(id: "edit", title: "Open Settings", symbol: "gearshape") { context in
                context.app.settingsWindow.show(.launcher)
            }
        }
        return LauncherItem(id: "\(id):\(command.rawValue)", title: command.title, subtitle: subtitle,
                            icon: .symbol(command.symbol, Brand.leaf), accessory: "Focus", actions: [action])
    }

    static func blockSummary(_ list: FocusBlockList) -> String {
        let apps = list.apps.count == 1 ? "1 app" : "\(list.apps.count) apps"
        let sites = list.domains.count == 1 ? "1 website" : "\(list.domains.count) websites"
        return list.apps.isEmpty && list.domains.isEmpty ? "Nothing blocked yet: add apps and websites in Settings"
                                                         : "Blocks \(apps) and \(sites)"
    }
}

/// Start Focus Session: what's typed is the goal (optionally after a duration: "45m write the report"); pick how long.
final class FocusStartMode: LauncherMode {
    let title = "Start Focus Session"
    let placeholder = "What are you focusing on?"
    let icon = LauncherIcon.symbol("target", Brand.leaf)
    var keysHint: String? { "Type a goal, then pick how long" }

    private static let presets: [(id: String, title: String, seconds: TimeInterval?)] = [
        ("10", "10 minutes", 600), ("25", "25 minutes", 1500), ("50", "50 minutes", 3000), ("60", "1 hour", 3600),
        ("120", "2 hours", 7200), ("open", "Until stopped", nil),
    ]

    func items(for query: LauncherQuery) async -> [LauncherItem] {
        let blocks = FocusProvider.blockSummary(FocusController.shared.blockList)
        var items: [LauncherItem] = []
        var goal = query.text
        if let typed = FocusDuration.parse(query.text) {
            goal = typed.goal
            items.append(makeItem(id: "typed", title: "Focus for \(FocusDuration.describe(typed.seconds))",
                                  seconds: typed.seconds, goal: goal, subtitle: goal.isEmpty ? blocks : goal,
                                  score: 1, section: .named("Typed", order: 0)))
        }
        for (index, preset) in Self.presets.enumerated() {
            items.append(makeItem(id: preset.id, title: preset.title, seconds: preset.seconds, goal: goal,
                                  subtitle: goal.isEmpty ? blocks : "“\(goal)”",
                                  score: 0.9 - Double(index) * 0.01, section: .named("Duration", order: 1)))
        }
        return items
    }

    private func makeItem(id: String, title: String, seconds: TimeInterval?, goal: String, subtitle: String,
                          score: Double, section: LauncherSection) -> LauncherItem {
        LauncherItem(id: "focus:duration-\(id)", title: title, subtitle: subtitle,
                     icon: .symbol(seconds == nil ? "infinity" : "timer", Brand.leaf), section: section, score: score,
                     actions: [LauncherAction(id: "begin", title: "Start Focus Session", symbol: "target") { _ in
                         FocusController.shared.begin(goal: goal, duration: seconds)
                     }],
                     tracksUsage: false)
    }
}

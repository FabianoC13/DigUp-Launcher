import AppKit
import DigUpKit
import SwiftUI

/// Window management (layouts, displays), Switch Windows and Search Menu Items.
///
/// Layout commands act on the front window of the app you came from (`LauncherContext.previousApp`), through the
/// Accessibility API: the panel hides, that app is in front again, and its window moves. Items are "win:<key>".
enum WindowsFeature: LauncherFeature {
    static func providers(_ launcher: Launcher) -> [any LauncherProvider] {
        [CommandsProvider()]
    }

    static var settingsTitle: String? { "Window Management" }

    static func settingsView(_ launcher: Launcher) -> AnyView {
        AnyView(SettingsView())
    }

    static let prefix = "win"

    /// What a window command does.
    enum Action {
        case layout(LauncherWindowLayout)
        case restore
        /// To the next (1) or previous (-1) display.
        case display(Int)
        case toggleFullScreen
        case switchWindows
        case searchMenuItems
    }

    /// One window command, as the root search lists it.
    struct Command {
        let key: String
        let title: String
        var keywords: [String] = []
        let symbol: String
        let action: Action

        var id: String { "\(WindowsFeature.prefix):\(key)" }

        func item(score: Double = 0.5) -> LauncherItem {
            let isMode: Bool
            switch action {
            case .switchWindows, .searchMenuItems: isMode = true
            default: isMode = false
            }
            let action = LauncherAction(id: "run", title: title, symbol: symbol, keepsPanelOpen: true) { context in
                await WindowsFeature.run(self.action, context: context)
            }
            return LauncherItem(id: id, title: title, icon: .symbol(symbol), accessory: isMode ? "Command" : "Window",
                                score: score, actions: [action], metadata: [("Needs", "Accessibility")],
                                tracksUsage: true)
        }
    }

    /// The root search's "win" items: the commands whose name or keywords match.
    private final class CommandsProvider: LauncherProvider {
        let id = WindowsFeature.prefix

        func items(for query: LauncherQuery) async -> [LauncherItem] {
            guard !query.isEmpty else { return [] }
            return WindowsFeature.commands.compactMap { command in
                query.match(command.title, keywords: command.keywords).map { command.item(score: $0) }
            }
        }

        func item(id: String) async -> LauncherItem? {
            WindowsFeature.commands.first { $0.id == id }?.item()
        }
    }

    /// Runs a command: the modes push their list; the others need Accessibility and a window to act on.
    static func run(_ action: Action, context: LauncherContext) async {
        guard Accessibility.isTrusted(prompt: true) else {
            SystemHUD.report("Allow DigUp in Privacy & Security → Accessibility for window commands",
                             symbol: "lock.shield", context: context)
            return
        }
        switch action {
        case .switchWindows:
            context.push(SwitchWindowsMode())
        case .searchMenuItems:
            guard let app = SystemFeature.appInFront(context), !app.isTerminated else {
                SystemHUD.report("Open the launcher over an app to search its menus", symbol: "menubar.rectangle",
                                 context: context)
                return
            }
            context.push(MenuItemsMode(app: app))
        case .layout, .restore, .display, .toggleFullScreen:
            await arrange(action, context: context)
        }
    }

    // MARK: Settings

    static let gapKey = "launcherWindowGap"
    static let gapRange = 0...20

    /// Points left between windows, and between a window and the display's edges.
    static var gap: Double {
        Double(min(gapRange.upperBound, max(gapRange.lowerBound, AppSettings.defaults.integer(forKey: gapKey))))
    }

    static let cycleKey = "launcherWindowCycleHalves"

    /// Running Left, Right, Top or Bottom Half again goes on to two thirds, then a third (on unless turned off).
    static var cyclesHalves: Bool {
        AppSettings.defaults.object(forKey: cycleKey) as? Bool ?? true
    }

    private struct SettingsView: View {
        @AppStorage(WindowsFeature.gapKey, store: AppSettings.defaults) private var gap = 0
        @AppStorage(WindowsFeature.cycleKey, store: AppSettings.defaults) private var cycles = true

        var body: some View {
            LabeledContent("Gap between windows") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(gap) }, set: { gap = Int($0.rounded()) }),
                           in: Double(WindowsFeature.gapRange.lowerBound)...Double(WindowsFeature.gapRange.upperBound),
                           step: 1)
                        .frame(width: 160)
                    Text("\(gap) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Text("Halves, thirds, quarters and Maximize leave this much room around windows and between them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Repeating a half cycles through ½, ⅔ and ⅓", isOn: $cycles)
            Text("Run Left Half again while the window is still there, and it takes two thirds of the display, then a "
                 + "third, then half again. The same for Right, Top and Bottom Half.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: The commands

extension WindowsFeature {
    private static let windowWords = ["window", "snap", "resize", "move"]

    /// Every window command, in the order they're listed when several match equally.
    static let commands: [Command] = layoutCommands + [
        Command(key: "restore", title: "Restore", keywords: windowWords + ["undo", "previous size", "original"],
                symbol: "arrow.uturn.backward", action: .restore),
        Command(key: "next-display", title: "Next Display", keywords: windowWords + ["monitor", "screen", "move to"],
                symbol: "arrow.right.square", action: .display(1)),
        Command(key: "previous-display", title: "Previous Display",
                keywords: windowWords + ["monitor", "screen", "move to"], symbol: "arrow.left.square",
                action: .display(-1)),
        Command(key: "toggle-fullscreen", title: "Toggle Fullscreen",
                keywords: windowWords + ["full screen", "enter fullscreen", "exit fullscreen"],
                symbol: "arrow.up.backward.and.arrow.down.forward.square", action: .toggleFullScreen),
        Command(key: "switch", title: "Switch Windows",
                keywords: ["windows", "window switcher", "focus window", "alt tab", "go to window"],
                symbol: "macwindow.on.rectangle", action: .switchWindows),
        Command(key: "menu", title: "Search Menu Items",
                keywords: ["menu bar", "menus", "commands", "menu item", "run menu"], symbol: "filemenu.and.selection",
                action: .searchMenuItems),
    ]

    private static let layoutCommands: [Command] = LauncherWindowLayout.allCases.map { layout in
        let (title, symbol, extra) = describe(layout)
        return Command(key: layout.rawValue, title: title, keywords: windowWords + extra, symbol: symbol,
                       action: .layout(layout))
    }

    /// A layout's name, SF Symbol and extra words to find it by.
    private static func describe(_ layout: LauncherWindowLayout) -> (String, String, [String]) {
        switch layout {
        case .leftHalf: ("Left Half", "rectangle.lefthalf.filled", ["split", "tile"])
        case .rightHalf: ("Right Half", "rectangle.righthalf.filled", ["split", "tile"])
        case .topHalf: ("Top Half", "rectangle.tophalf.filled", ["split", "tile"])
        case .bottomHalf: ("Bottom Half", "rectangle.bottomhalf.filled", ["split", "tile"])
        case .centerHalf: ("Center Half", "rectangle.center.inset.filled", ["middle"])
        case .topLeftQuarter: ("Top Left Quarter", "rectangle.inset.topleft.filled", ["corner"])
        case .topRightQuarter: ("Top Right Quarter", "rectangle.inset.topright.filled", ["corner"])
        case .bottomLeftQuarter: ("Bottom Left Quarter", "rectangle.inset.bottomleft.filled", ["corner"])
        case .bottomRightQuarter: ("Bottom Right Quarter", "rectangle.inset.bottomright.filled", ["corner"])
        case .firstThird: ("First Third", "rectangle.leftthird.inset.filled", ["left third", "column"])
        case .centerThird: ("Center Third", "rectangle.split.3x1.fill", ["middle third", "column"])
        case .lastThird: ("Last Third", "rectangle.rightthird.inset.filled", ["right third", "column"])
        case .firstTwoThirds: ("First Two Thirds", "rectangle.lefthalf.inset.filled", ["left two thirds"])
        case .centerTwoThirds: ("Center Two Thirds", "rectangle.split.3x1", ["middle two thirds"])
        case .lastTwoThirds: ("Last Two Thirds", "rectangle.righthalf.inset.filled", ["right two thirds"])
        case .firstFourth: ("First Fourth", "square.grid.4x3.fill", ["left quarter column", "column"])
        case .secondFourth: ("Second Fourth", "square.grid.4x3.fill", ["column"])
        case .thirdFourth: ("Third Fourth", "square.grid.4x3.fill", ["column"])
        case .lastFourth: ("Last Fourth", "square.grid.4x3.fill", ["right quarter column", "column"])
        case .topLeftSixth: ("Top Left Sixth", "square.grid.3x2.fill", ["grid"])
        case .topCenterSixth: ("Top Center Sixth", "square.grid.3x2.fill", ["grid"])
        case .topRightSixth: ("Top Right Sixth", "square.grid.3x2.fill", ["grid"])
        case .bottomLeftSixth: ("Bottom Left Sixth", "square.grid.3x2.fill", ["grid"])
        case .bottomCenterSixth: ("Bottom Center Sixth", "square.grid.3x2.fill", ["grid"])
        case .bottomRightSixth: ("Bottom Right Sixth", "square.grid.3x2.fill", ["grid"])
        case .maximize: ("Maximize", "arrow.up.left.and.arrow.down.right", ["fill", "full size", "zoom"])
        case .almostMaximize: ("Almost Maximize", "rectangle.inset.filled", ["nearly", "90%"])
        case .maximizeWidth: ("Maximize Width", "arrow.left.and.right", ["full width", "stretch"])
        case .maximizeHeight: ("Maximize Height", "arrow.up.and.down", ["full height", "stretch"])
        case .center: ("Center", "dot.square", ["middle", "centre"])
        case .reasonableSize: ("Reasonable Size", "rectangle.ratio.4.to.3", ["default size", "medium"])
        case .makeLarger: ("Make Larger", "rectangle.arrowtriangle.2.outward", ["bigger", "grow", "increase"])
        case .makeSmaller: ("Make Smaller", "rectangle.arrowtriangle.2.inward", ["shrink", "decrease"])
        case .moveUp: ("Move Up", "arrow.up.to.line", ["top edge"])
        case .moveDown: ("Move Down", "arrow.down.to.line", ["bottom edge"])
        case .moveLeft: ("Move Left", "arrow.left.to.line", ["left edge"])
        case .moveRight: ("Move Right", "arrow.right.to.line", ["right edge"])
        }
    }
}

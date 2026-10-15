import Foundation
import Testing
@testable import DigUpKit

/// A 1440×900 main display with a 25 pt menu bar and a 50 pt Dock at the bottom: its visible frame is (0, 50, 1440,
/// 825) in AppKit's coordinates, (0, 25, 1440, 825) in the Accessibility API's.
private let main = LauncherWindowRect(x: 0, y: 25, width: 1440, height: 825)

private func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LauncherWindowRect {
    LauncherWindowRect(x: x, y: y, width: width, height: height)
}

private func frame(_ layout: LauncherWindowLayout, window: LauncherWindowRect = rect(100, 100, 600, 400),
                   screen: LauncherWindowRect = main, gap: Double = 0) -> LauncherWindowRect {
    LauncherWindowGeometry.frame(for: layout, window: window, screen: screen, gap: gap)
}

@Suite struct LauncherWindowsCoordinateTests {
    @Test func flipsTheMainDisplaysVisibleFrame() {
        let appKit = rect(0, 50, 1440, 825)
        #expect(LauncherWindowGeometry.flipped(appKit, mainHeight: 900) == main)
    }

    @Test func flipIsItsOwnInverse() {
        let r = rect(-300, 120, 800, 600)
        #expect(LauncherWindowGeometry.flipped(LauncherWindowGeometry.flipped(r, mainHeight: 1117), mainHeight: 1117) == r)
    }

    @Test func displaysAboveAndBesideTheMainOne() {
        // A 1920×1080 display above the main one: negative y in Accessibility coordinates.
        #expect(LauncherWindowGeometry.flipped(rect(0, 900, 1920, 1080), mainHeight: 900) == rect(0, -1080, 1920, 1080))
        // To its left, bottoms aligned 180 pt lower: its top lines up with the main display's top.
        #expect(LauncherWindowGeometry.flipped(rect(-1920, -180, 1920, 1080), mainHeight: 900) == rect(-1920, 0, 1920, 1080))
        // Below it.
        #expect(LauncherWindowGeometry.flipped(rect(200, -1080, 1920, 1080), mainHeight: 900) == rect(200, 900, 1920, 1080))
    }
}

@Suite struct LauncherWindowsLayoutTests {
    @Test func halvesWithoutGaps() {
        #expect(frame(.leftHalf) == rect(0, 25, 720, 825))
        #expect(frame(.rightHalf) == rect(720, 25, 720, 825))
        #expect(frame(.topHalf) == rect(0, 25, 1440, 412.5))
        #expect(frame(.bottomHalf) == rect(0, 437.5, 1440, 412.5))
        #expect(frame(.centerHalf) == rect(360, 25, 720, 825))
    }

    @Test func gapsAtTheEdgesAndOneGapBetweenNeighbours() {
        let left = frame(.leftHalf, gap: 10), right = frame(.rightHalf, gap: 10)
        #expect(left == rect(10, 35, 705, 805))
        #expect(right == rect(725, 35, 705, 805))
        #expect(right.minX - left.maxX == 10)
        #expect(frame(.maximize, gap: 10) == rect(10, 35, 1420, 805))
        let topLeft = frame(.topLeftQuarter, gap: 8), bottomLeft = frame(.bottomLeftQuarter, gap: 8)
        #expect(bottomLeft.minY - topLeft.maxY == 8)
        #expect(topLeft.minX == 8 && topLeft.minY == 33)
    }

    @Test func quartersTileTheDisplay() {
        let quarters: [LauncherWindowLayout] = [.topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter]
        let total = quarters.map { frame($0).area }.reduce(0, +)
        #expect(total == main.area)
        #expect(frame(.bottomRightQuarter) == rect(720, 437.5, 720, 412.5))
    }

    @Test func thirdsAndTwoThirds() {
        #expect(frame(.firstThird) == rect(0, 25, 480, 825))
        #expect(frame(.centerThird) == rect(480, 25, 480, 825))
        #expect(frame(.lastThird) == rect(960, 25, 480, 825))
        #expect(frame(.firstTwoThirds) == rect(0, 25, 960, 825))
        #expect(frame(.lastTwoThirds) == rect(480, 25, 960, 825))
        #expect(frame(.centerTwoThirds) == rect(240, 25, 960, 825))
    }

    @Test func fourthsAndSixths() {
        #expect(frame(.firstFourth) == rect(0, 25, 360, 825))
        #expect(frame(.thirdFourth) == rect(720, 25, 360, 825))
        #expect(frame(.lastFourth) == rect(1080, 25, 360, 825))
        #expect(frame(.topCenterSixth) == rect(480, 25, 480, 412.5))
        #expect(frame(.bottomRightSixth) == rect(960, 437.5, 480, 412.5))
    }

    @Test func thirdsAreRowsOnAPortraitDisplay() {
        let portrait = rect(1440, -200, 1080, 1920)
        #expect(frame(.firstThird, screen: portrait) == rect(1440, -200, 1080, 640))
        #expect(frame(.lastTwoThirds, screen: portrait) == rect(1440, 440, 1080, 1280))
        // Halves stay left and right.
        #expect(frame(.leftHalf, screen: portrait) == rect(1440, -200, 540, 1920))
    }

    @Test func maximizeVariants() {
        #expect(frame(.maximize) == main)
        #expect(frame(.almostMaximize) == rect(72, 66.25, 1296, 742.5))
        let window = rect(300, 200, 500, 300)
        #expect(frame(.maximizeWidth, window: window) == rect(0, 200, 1440, 300))
        #expect(frame(.maximizeHeight, window: window) == rect(300, 25, 500, 825))
        #expect(frame(.maximizeWidth, window: window, gap: 6) == rect(6, 200, 1428, 300))
    }

    @Test func centerKeepsTheSizeAndFitsTheDisplay() {
        #expect(frame(.center, window: rect(0, 25, 600, 400)) == rect(420, 237.5, 600, 400))
        // Too big for the display: it shrinks to fit.
        #expect(frame(.center, window: rect(-50, 0, 2000, 1000)) == main)
    }

    @Test func reasonableSizeIsCappedAndCentered() {
        let small = frame(.reasonableSize)
        #expect(small == rect(288, 148.75, 864, 577.5))
        let big = frame(.reasonableSize, screen: rect(0, 25, 2560, 1415))
        #expect(big.width == 1025 && big.height == 900)
        #expect(big.midX == 1280)
    }

    @Test func makeLargerAndSmallerKeepTheCenterWithinLimits() {
        let window = rect(420, 237.5, 600, 400)
        let larger = frame(.makeLarger, window: window)
        #expect(larger.width == 744 && larger.height == 482.5)
        #expect(larger.midX == window.midX && larger.midY == window.midY)
        let smaller = frame(.makeSmaller, window: window)
        #expect(smaller.width == 456 && smaller.height == 317.5)
        // It never gets smaller than a quarter of the display, nor bigger than it.
        #expect(frame(.makeSmaller, window: rect(600, 300, 380, 220)).width == 360)
        #expect(frame(.makeLarger, window: rect(0, 25, 1400, 800)) == main)
        // Against an edge, it grows away from it.
        let atLeft = frame(.makeLarger, window: rect(0, 25, 720, 825))
        #expect(atLeft.minX == 0 && atLeft.width == 864)
    }

    @Test func movesFlushToEachEdgeKeepingTheSize() {
        let window = rect(300, 200, 500, 300)
        #expect(frame(.moveLeft, window: window) == rect(0, 200, 500, 300))
        #expect(frame(.moveRight, window: window) == rect(940, 200, 500, 300))
        #expect(frame(.moveUp, window: window) == rect(300, 25, 500, 300))
        #expect(frame(.moveDown, window: window) == rect(300, 550, 500, 300))
        #expect(frame(.moveRight, window: window, gap: 10) == rect(930, 200, 500, 300))
    }

    @Test func everyLayoutStaysOnTheDisplay() {
        let screens = [main, rect(-1920, -300, 1920, 1080), rect(1440, -200, 1080, 1920)]
        let windows = [rect(100, 100, 600, 400), rect(-5000, 3000, 4000, 4000), rect(1300, 800, 300, 200)]
        for screen in screens {
            for window in windows {
                for layout in LauncherWindowLayout.allCases {
                    for gap in [0.0, 12] {
                        let result = frame(layout, window: window, screen: screen, gap: gap)
                        #expect(result.width >= 1 && result.height >= 1, "\(layout) \(screen) \(window)")
                        #expect(result.minX >= screen.minX - 0.0001 && result.maxX <= screen.maxX + 0.0001,
                                "\(layout) on \(screen) for \(window): \(result)")
                        #expect(result.minY >= screen.minY - 0.0001 && result.maxY <= screen.maxY + 0.0001,
                                "\(layout) on \(screen) for \(window): \(result)")
                    }
                }
            }
        }
    }

    @Test func idsAreStable() {
        #expect(LauncherWindowLayout.leftHalf.rawValue == "left-half")
        #expect(LauncherWindowLayout(rawValue: "bottom-right-quarter") == .bottomRightQuarter)
        #expect(Set(LauncherWindowLayout.allCases.map(\.rawValue)).count == LauncherWindowLayout.allCases.count)
    }
}

@Suite struct LauncherWindowsDisplayTests {
    let left = rect(-1920, 0, 1920, 1055)
    let right = rect(1440, -200, 1080, 1895)

    @Test func theDisplayAWindowIsOnIsTheOneItOverlapsMost() {
        let screens = [main, left, right]
        #expect(LauncherWindowGeometry.screenIndex(of: rect(100, 100, 500, 400), in: screens) == 0)
        // Mostly on the left display.
        #expect(LauncherWindowGeometry.screenIndex(of: rect(-700, 100, 800, 400), in: screens) == 1)
        // Off every display: the nearest one.
        #expect(LauncherWindowGeometry.screenIndex(of: rect(3000, 0, 100, 100), in: screens) == 2)
        #expect(LauncherWindowGeometry.screenIndex(of: rect(0, 0, 10, 10), in: []) == nil)
    }

    @Test func nextAndPreviousGoLeftToRightAndWrap() {
        let screens = [main, left, right]
        #expect(LauncherWindowGeometry.displayOrder(screens) == [1, 0, 2])
        #expect(LauncherWindowGeometry.neighbor(of: 0, in: screens, step: 1) == 2)
        #expect(LauncherWindowGeometry.neighbor(of: 2, in: screens, step: 1) == 1)
        #expect(LauncherWindowGeometry.neighbor(of: 1, in: screens, step: -1) == 2)
        #expect(LauncherWindowGeometry.neighbor(of: 0, in: [main], step: 1) == 0)
    }

    @Test func movingToAnotherDisplayKeepsTheRelativePlaceAndSize() {
        // The left half of the main display becomes the left half of the left display.
        let leftHalf = rect(0, 25, 720, 825)
        #expect(LauncherWindowGeometry.transfer(leftHalf, from: main, to: left) == rect(-1920, 0, 960, 1055))
        // A window in the middle stays in the middle.
        let middle = rect(420, 237.5, 600, 400)
        let moved = LauncherWindowGeometry.transfer(middle, from: main, to: right)
        #expect(abs(moved.midX - right.midX) < 0.001 && abs(moved.midY - right.midY) < 0.001)
        #expect(abs(moved.width - 450) < 0.001)
        // And back again.
        let back = LauncherWindowGeometry.transfer(moved, from: right, to: main)
        #expect(abs(back.minX - middle.minX) < 0.001 && abs(back.height - middle.height) < 0.001)
    }

    @Test func aWindowPartlyOffItsDisplayLandsInsideTheNextOne() {
        let hanging = rect(1200, 700, 600, 400)
        let moved = LauncherWindowGeometry.transfer(hanging, from: main, to: left)
        #expect(moved.minX >= left.minX && moved.maxX <= left.maxX)
        #expect(moved.minY >= left.minY && moved.maxY <= left.maxY)
    }

    @Test func clampingShrinksThenMovesInside() {
        #expect(LauncherWindowGeometry.clamped(rect(1300, 800, 400, 300), to: main) == rect(1040, 550, 400, 300))
        #expect(LauncherWindowGeometry.clamped(rect(-100, -100, 3000, 3000), to: main) == main)
    }

    @Test func overlapArea() {
        #expect(rect(0, 0, 100, 100).overlap(with: rect(50, 50, 100, 100)) == 2500)
        #expect(rect(0, 0, 100, 100).overlap(with: rect(100, 0, 100, 100)) == 0)
    }
}

@Suite struct LauncherWindowsMenuTests {
    @Test func commandShortcuts() {
        #expect(LauncherMenuShortcut.display(character: "s", modifiers: 0, glyph: nil) == "⌘S")
        #expect(LauncherMenuShortcut.display(character: "S", modifiers: LauncherMenuShortcut.shift, glyph: nil) == "⇧⌘S")
        let all = LauncherMenuShortcut.control | LauncherMenuShortcut.option | LauncherMenuShortcut.shift
        #expect(LauncherMenuShortcut.display(character: "f", modifiers: all, glyph: nil) == "⌃⌥⇧⌘F")
        #expect(LauncherMenuShortcut.display(character: ",", modifiers: nil, glyph: nil) == "⌘,")
    }

    @Test func specialKeysByCharacterOrGlyph() {
        // AppKit's function-key characters.
        #expect(LauncherMenuShortcut.display(character: "\u{F702}", modifiers: LauncherMenuShortcut.option,
                                             glyph: nil) == "⌥⌘←")
        #expect(LauncherMenuShortcut.display(character: "\u{F70E}", modifiers: LauncherMenuShortcut.noCommand,
                                             glyph: nil) == "F11")
        #expect(LauncherMenuShortcut.display(character: "\u{7F}", modifiers: 0, glyph: nil) == "⌘⌫")
        // No character: the Menu Manager glyph.
        #expect(LauncherMenuShortcut.display(character: nil, modifiers: LauncherMenuShortcut.control, glyph: 0x6F)
                == "⌃⌘F1")
        #expect(LauncherMenuShortcut.display(character: "", modifiers: 0, glyph: 0x0B) == "⌘↩")
        #expect(LauncherMenuShortcut.display(character: nil, modifiers: 0, glyph: 0x8C) == "⌘⏏")
    }

    @Test func noShortcut() {
        #expect(LauncherMenuShortcut.display(character: nil, modifiers: nil, glyph: nil) == nil)
        #expect(LauncherMenuShortcut.display(character: "", modifiers: 0, glyph: 0) == nil)
        #expect(LauncherMenuShortcut.display(character: "\u{1}", modifiers: 0, glyph: nil) == nil)
    }

    @Test func pathsAndWhereTheWalkGoes() {
        #expect(LauncherMenuPath.display(["File", "Export"]) == "File › Export")
        #expect(!LauncherMenuPath.shouldWalk(menuIndex: 0, depth: 0))
        #expect(LauncherMenuPath.shouldWalk(menuIndex: 1, depth: 0))
        #expect(LauncherMenuPath.shouldWalk(menuIndex: 0, depth: 2))
        #expect(!LauncherMenuPath.shouldWalk(menuIndex: 3, depth: 5))
    }
}

@Suite struct LauncherWindowsCyclingTests {
    private func cycled(_ layout: LauncherWindowLayout, _ step: Int, screen: LauncherWindowRect = main,
                        gap: Double = 0) -> LauncherWindowRect {
        LauncherWindowGeometry.cycledFrame(for: layout, step: step, window: rect(100, 100, 600, 400), screen: screen,
                                           gap: gap)
    }

    @Test func theFirstStepIsTheHalf() {
        for layout in [LauncherWindowLayout.leftHalf, .rightHalf, .topHalf, .bottomHalf] {
            #expect(cycled(layout, 0) == frame(layout))
            #expect(cycled(layout, 0, gap: 8) == frame(layout, gap: 8))
        }
    }

    @Test func halvesGoToTwoThirdsThenAThirdThenRoundAgain() {
        #expect(cycled(.leftHalf, 1) == rect(0, 25, 960, 825))
        #expect(cycled(.leftHalf, 2) == rect(0, 25, 480, 825))
        #expect(cycled(.leftHalf, 3) == cycled(.leftHalf, 0))
        #expect(cycled(.rightHalf, 1) == rect(480, 25, 960, 825))
        #expect(cycled(.rightHalf, 2) == rect(960, 25, 480, 825))
        // 825 / 6 = 137.5 points a row.
        #expect(cycled(.topHalf, 1) == rect(0, 25, 1440, 550))
        #expect(cycled(.bottomHalf, 2) == rect(0, 25 + 550, 1440, 275))
    }

    @Test func leftAndRightStayColumnsOnAPortraitDisplay() {
        let portrait = rect(0, 0, 1080, 1920)
        #expect(cycled(.leftHalf, 1, screen: portrait) == rect(0, 0, 720, 1920))
        #expect(cycled(.topHalf, 2, screen: portrait) == rect(0, 0, 1080, 640))
    }

    @Test func otherLayoutsDontCycle() {
        #expect(!LauncherWindowLayout.maximize.cycles)
        #expect(!LauncherWindowLayout.firstThird.cycles)
        #expect(cycled(.maximize, 2) == frame(.maximize))
        #expect(LauncherWindowGeometry.cycleStep(of: frame(.maximize), for: .maximize, screen: main) == nil)
    }

    @Test func findsTheStepAWindowIsAtAndTheNextOne() {
        let half = cycled(.leftHalf, 0, gap: 6)
        #expect(LauncherWindowGeometry.cycleStep(of: half, for: .leftHalf, screen: main, gap: 6) == 0)
        // An app that rounds its size to a step of its own is still in place.
        let nearlyTwoThirds = rect(0 + 6, 25 + 6, 960 - 6 - 3 - 1, 825 - 12 + 1)
        #expect(LauncherWindowGeometry.cycleStep(of: nearlyTwoThirds, for: .leftHalf, screen: main, gap: 6) == 1)
        #expect(LauncherWindowGeometry.cycleStep(of: rect(100, 100, 600, 400), for: .leftHalf, screen: main) == nil)
        // The left half isn't a step of Right Half's cycle.
        #expect(LauncherWindowGeometry.cycleStep(of: half, for: .rightHalf, screen: main, gap: 6) == nil)
        #expect(LauncherWindowGeometry.nextCycleStep(after: nil) == 0)
        #expect(LauncherWindowGeometry.nextCycleStep(after: 0) == 1)
        #expect(LauncherWindowGeometry.nextCycleStep(after: 2) == 0)
    }
}

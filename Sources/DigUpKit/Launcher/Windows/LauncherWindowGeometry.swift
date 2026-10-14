import Foundation

/// A rectangle in points, in the Accessibility API's global coordinates: the origin is the top left of the main display
/// and y grows downward (a display above the main one has negative y). Plain doubles, so the window math runs and is
/// tested on any platform.
public struct LauncherWindowRect: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { max(0, width) * max(0, height) }

    /// The area both rectangles cover (0 when they don't overlap).
    public func overlap(with other: LauncherWindowRect) -> Double {
        let width = min(maxX, other.maxX) - max(minX, other.minX)
        let height = min(maxY, other.maxY) - max(minY, other.minY)
        return width > 0 && height > 0 ? width * height : 0
    }

    /// Whole points: windows sit on them, and comparing frames after a round trip through an app needs it.
    public var rounded: LauncherWindowRect {
        LauncherWindowRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }

    public var description: String {
        "(\(Self.format(x)), \(Self.format(y)), \(Self.format(width))×\(Self.format(height)))"
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Where a window command puts the window, relative to its display's usable area (the visible frame: no menu bar, no
/// Dock). The raw value is the command's stable id ("win:left-half").
public enum LauncherWindowLayout: String, CaseIterable, Sendable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"
    case centerHalf = "center-half"
    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"
    case firstThird = "first-third"
    case centerThird = "center-third"
    case lastThird = "last-third"
    case firstTwoThirds = "first-two-thirds"
    case centerTwoThirds = "center-two-thirds"
    case lastTwoThirds = "last-two-thirds"
    case firstFourth = "first-fourth"
    case secondFourth = "second-fourth"
    case thirdFourth = "third-fourth"
    case lastFourth = "last-fourth"
    case topLeftSixth = "top-left-sixth"
    case topCenterSixth = "top-center-sixth"
    case topRightSixth = "top-right-sixth"
    case bottomLeftSixth = "bottom-left-sixth"
    case bottomCenterSixth = "bottom-center-sixth"
    case bottomRightSixth = "bottom-right-sixth"
    case maximize
    case almostMaximize = "almost-maximize"
    case maximizeWidth = "maximize-width"
    case maximizeHeight = "maximize-height"
    case center
    case reasonableSize = "reasonable-size"
    case makeLarger = "make-larger"
    case makeSmaller = "make-smaller"
    case moveUp = "move-up"
    case moveDown = "move-down"
    case moveLeft = "move-left"
    case moveRight = "move-right"
}

/// The arithmetic of window commands: layouts on a display, gaps, the flip between AppKit's and the Accessibility API's
/// coordinates, and moving a window to another display. All rectangles are in Accessibility coordinates
/// (`LauncherWindowRect`), except the input and output of `flipped`.
public enum LauncherWindowGeometry {
    /// Almost Maximize takes this much of the display's width and height.
    public static let almostMaximizeFraction = 0.9
    /// Reasonable Size: this much of the display's width and height, up to `reasonableMaximum` points.
    public static let reasonableFraction = (width: 0.6, height: 0.7)
    public static let reasonableMaximum = (width: 1025.0, height: 900.0)
    /// Make Larger / Make Smaller change the width and height by this much of the display's, half on each side.
    public static let resizeStep = 0.1
    /// Make Smaller stops at this much of the display's width and height.
    public static let smallestFraction = 0.25

    // MARK: Coordinates

    /// Between AppKit's screen coordinates (origin at the bottom left of the main display, y up) and the Accessibility
    /// API's (origin at its top left, y down). The flip is its own inverse, so it converts either way. `mainHeight` is
    /// the main display's height (`NSScreen.screens[0].frame.height`, the display with the menu bar).
    public static func flipped(_ rect: LauncherWindowRect, mainHeight: Double) -> LauncherWindowRect {
        LauncherWindowRect(x: rect.x, y: mainHeight - rect.y - rect.height, width: rect.width, height: rect.height)
    }

    // MARK: Displays

    /// The display a window is on: the one it overlaps most, or, when it's on none of them, the one whose center is
    /// nearest to its center. Nil only without displays.
    public static func screenIndex(of window: LauncherWindowRect, in screens: [LauncherWindowRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let overlaps = screens.map { $0.overlap(with: window) }
        if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 { return best }
        func distance(_ screen: LauncherWindowRect) -> Double {
            let dx = screen.midX - window.midX, dy = screen.midY - window.midY
            return dx * dx + dy * dy
        }
        return screens.indices.min { distance(screens[$0]) < distance(screens[$1]) }
    }

    /// Displays from left to right (top to bottom where they're side by side), as indices into `screens`: the order
    /// Next Display and Previous Display go through.
    public static func displayOrder(_ screens: [LauncherWindowRect]) -> [Int] {
        screens.indices.sorted { a, b in
            screens[a].minX != screens[b].minX ? screens[a].minX < screens[b].minX : screens[a].minY < screens[b].minY
        }
    }

    /// The display after (`step` 1) or before (`step` -1) the one at `index`, in `displayOrder`, wrapping around.
    public static func neighbor(of index: Int, in screens: [LauncherWindowRect], step: Int) -> Int {
        let order = displayOrder(screens)
        guard let position = order.firstIndex(of: index), !order.isEmpty else { return index }
        let count = order.count
        return order[((position + step) % count + count) % count]
    }

    /// `window`, moved from one display's usable area to another's: it keeps where it sits and how much of the display
    /// it takes (a left half stays a left half), then fits inside the new display.
    public static func transfer(_ window: LauncherWindowRect, from source: LauncherWindowRect,
                                to target: LauncherWindowRect) -> LauncherWindowRect {
        guard source.width > 0, source.height > 0 else { return clamped(window, to: target) }
        // As fractions of the source display first: a half stays exactly a half.
        let moved = LauncherWindowRect(x: target.minX + (window.minX - source.minX) / source.width * target.width,
                                       y: target.minY + (window.minY - source.minY) / source.height * target.height,
                                       width: window.width / source.width * target.width,
                                       height: window.height / source.height * target.height)
        return clamped(moved, to: target)
    }

    /// No bigger than `area`, and moved inside it.
    public static func clamped(_ rect: LauncherWindowRect, to area: LauncherWindowRect) -> LauncherWindowRect {
        let width = min(rect.width, area.width), height = min(rect.height, area.height)
        let x = min(max(rect.minX, area.minX), area.maxX - width)
        let y = min(max(rect.minY, area.minY), area.maxY - height)
        return LauncherWindowRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Layouts

    /// Where `layout` puts a window that is now at `window`, on a display whose usable area is `screen`, leaving `gap`
    /// points between the window and the display's edges and between windows side by side (half of it on each).
    ///
    /// Thirds and fourths split the long side: columns on a landscape display, rows on a portrait one.
    public static func frame(for layout: LauncherWindowLayout, window: LauncherWindowRect, screen: LauncherWindowRect,
                             gap: Double = 0) -> LauncherWindowRect {
        let gap = max(0, gap)
        let portrait = screen.height > screen.width
        // Columns along the long side (rows on a portrait display).
        func strip(_ parts: Int, _ index: Int, span: Int = 1) -> LauncherWindowRect {
            portrait ? cell(screen, columns: 1, column: 0, rows: parts, row: index, rowSpan: span, gap: gap)
                : cell(screen, columns: parts, column: index, columnSpan: span, rows: 1, row: 0, gap: gap)
        }
        func grid(_ columns: Int, _ rows: Int, _ column: Int, _ row: Int, columnSpan: Int = 1) -> LauncherWindowRect {
            cell(screen, columns: columns, column: column, columnSpan: columnSpan, rows: rows, row: row, gap: gap)
        }
        // The usable area inside the gap, for commands that keep the window's size.
        let inner = LauncherWindowRect(x: screen.minX + gap, y: screen.minY + gap,
                                       width: max(1, screen.width - 2 * gap), height: max(1, screen.height - 2 * gap))
        let kept = clamped(window, to: inner)
        switch layout {
        case .leftHalf: return grid(2, 1, 0, 0)
        case .rightHalf: return grid(2, 1, 1, 0)
        case .topHalf: return grid(1, 2, 0, 0)
        case .bottomHalf: return grid(1, 2, 0, 1)
        case .centerHalf: return grid(4, 1, 1, 0, columnSpan: 2)
        case .topLeftQuarter: return grid(2, 2, 0, 0)
        case .topRightQuarter: return grid(2, 2, 1, 0)
        case .bottomLeftQuarter: return grid(2, 2, 0, 1)
        case .bottomRightQuarter: return grid(2, 2, 1, 1)
        case .firstThird: return strip(3, 0)
        case .centerThird: return strip(3, 1)
        case .lastThird: return strip(3, 2)
        case .firstTwoThirds: return strip(3, 0, span: 2)
        case .centerTwoThirds: return strip(6, 1, span: 4)
        case .lastTwoThirds: return strip(3, 1, span: 2)
        case .firstFourth: return strip(4, 0)
        case .secondFourth: return strip(4, 1)
        case .thirdFourth: return strip(4, 2)
        case .lastFourth: return strip(4, 3)
        case .topLeftSixth: return grid(3, 2, 0, 0)
        case .topCenterSixth: return grid(3, 2, 1, 0)
        case .topRightSixth: return grid(3, 2, 2, 0)
        case .bottomLeftSixth: return grid(3, 2, 0, 1)
        case .bottomCenterSixth: return grid(3, 2, 1, 1)
        case .bottomRightSixth: return grid(3, 2, 2, 1)
        case .maximize: return grid(1, 1, 0, 0)
        case .almostMaximize:
            return centered(width: screen.width * almostMaximizeFraction, height: screen.height * almostMaximizeFraction,
                            in: screen)
        case .maximizeWidth:
            return LauncherWindowRect(x: inner.minX, y: kept.minY, width: inner.width, height: kept.height)
        case .maximizeHeight:
            return LauncherWindowRect(x: kept.minX, y: inner.minY, width: kept.width, height: inner.height)
        case .center:
            return centered(width: kept.width, height: kept.height, in: screen)
        case .reasonableSize:
            let width = min(screen.width * reasonableFraction.width, reasonableMaximum.width, inner.width)
            let height = min(screen.height * reasonableFraction.height, reasonableMaximum.height, inner.height)
            return centered(width: width, height: height, in: screen)
        case .makeLarger, .makeSmaller:
            let sign = layout == .makeLarger ? 1.0 : -1.0
            let smallest = (width: min(inner.width, screen.width * smallestFraction),
                            height: min(inner.height, screen.height * smallestFraction))
            let width = min(inner.width, max(smallest.width, window.width + sign * screen.width * resizeStep))
            let height = min(inner.height, max(smallest.height, window.height + sign * screen.height * resizeStep))
            let resized = LauncherWindowRect(x: window.midX - width / 2, y: window.midY - height / 2,
                                             width: width, height: height)
            return clamped(resized, to: inner)
        case .moveUp: return LauncherWindowRect(x: kept.minX, y: inner.minY, width: kept.width, height: kept.height)
        case .moveDown:
            return LauncherWindowRect(x: kept.minX, y: inner.maxY - kept.height, width: kept.width, height: kept.height)
        case .moveLeft: return LauncherWindowRect(x: inner.minX, y: kept.minY, width: kept.width, height: kept.height)
        case .moveRight:
            return LauncherWindowRect(x: inner.maxX - kept.width, y: kept.minY, width: kept.width, height: kept.height)
        }
    }

    /// One cell of a grid over `screen`, spanning `columnSpan` columns and `rowSpan` rows: inset by the whole gap where
    /// it meets the display's edge and by half of it where it meets a neighbouring cell, so that windows side by side
    /// have one gap between them.
    public static func cell(_ screen: LauncherWindowRect, columns: Int, column: Int, columnSpan: Int = 1,
                            rows: Int, row: Int, rowSpan: Int = 1, gap: Double = 0) -> LauncherWindowRect {
        let columns = max(1, columns), rows = max(1, rows)
        let cellWidth = screen.width / Double(columns), cellHeight = screen.height / Double(rows)
        let half = gap / 2
        let lastColumn = column + columnSpan >= columns, lastRow = row + rowSpan >= rows
        let minX = screen.minX + Double(column) * cellWidth + (column == 0 ? gap : half)
        let maxX = screen.minX + Double(column + columnSpan) * cellWidth - (lastColumn ? gap : half)
        let minY = screen.minY + Double(row) * cellHeight + (row == 0 ? gap : half)
        let maxY = screen.minY + Double(row + rowSpan) * cellHeight - (lastRow ? gap : half)
        return LauncherWindowRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    /// A rectangle of this size, centered in `area`.
    static func centered(width: Double, height: Double, in area: LauncherWindowRect) -> LauncherWindowRect {
        LauncherWindowRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }
}

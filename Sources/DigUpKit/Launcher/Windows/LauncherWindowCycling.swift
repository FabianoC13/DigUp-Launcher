import Foundation

extension LauncherWindowLayout {
    /// Left, Right, Top and Bottom Half: with cycling on, running one again while the window is still where it put
    /// it goes on to two thirds of the display along that side, then a third, then back to a half.
    public var cycles: Bool {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: true
        default: false
        }
    }
}

extension LauncherWindowGeometry {
    /// The sizes a cycling half goes through, in sixths of the display's side: a half, two thirds, a third.
    public static let cycleSpans = [3, 4, 2]

    /// Where step `step` of a cycling half puts the window (0: the half, 1: two thirds, 2: a third, then round
    /// again). Always columns for Left and Right Half and rows for Top and Bottom Half, whichever way the display
    /// turns. A layout that doesn't cycle gives what `frame(for:)` gives.
    public static func cycledFrame(for layout: LauncherWindowLayout, step: Int, window: LauncherWindowRect,
                                   screen: LauncherWindowRect, gap: Double = 0) -> LauncherWindowRect {
        guard layout.cycles else { return frame(for: layout, window: window, screen: screen, gap: gap) }
        let count = cycleSpans.count
        let span = cycleSpans[(step % count + count) % count]
        let gap = max(0, gap)
        switch layout {
        case .leftHalf:
            return cell(screen, columns: 6, column: 0, columnSpan: span, rows: 1, row: 0, gap: gap)
        case .rightHalf:
            return cell(screen, columns: 6, column: 6 - span, columnSpan: span, rows: 1, row: 0, gap: gap)
        case .topHalf:
            return cell(screen, columns: 1, column: 0, rows: 6, row: 0, rowSpan: span, gap: gap)
        default:
            return cell(screen, columns: 1, column: 0, rows: 6, row: 6 - span, rowSpan: span, gap: gap)
        }
    }

    /// Which step of `layout`'s cycle the window is at now (its frame within `tolerance` points of that step's), or
    /// nil when it's at none of them (it was moved, or another command placed it).
    public static func cycleStep(of window: LauncherWindowRect, for layout: LauncherWindowLayout,
                                 screen: LauncherWindowRect, gap: Double = 0, tolerance: Double = 2) -> Int? {
        guard layout.cycles else { return nil }
        return cycleSpans.indices.first { step in
            let frame = cycledFrame(for: layout, step: step, window: window, screen: screen, gap: gap)
            return abs(frame.minX - window.minX) <= tolerance && abs(frame.minY - window.minY) <= tolerance
                && abs(frame.width - window.width) <= tolerance && abs(frame.height - window.height) <= tolerance
        }
    }

    /// The step after `current` (nil: the window isn't in the cycle, so it starts at the half).
    public static func nextCycleStep(after current: Int?) -> Int {
        current.map { ($0 + 1) % cycleSpans.count } ?? 0
    }
}

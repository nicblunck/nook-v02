import CoreGraphics
import Foundation

/// Which way an arrow key is asking the cursor to go.
enum CanvasDirection: Hashable {
    case up, down, left, right

    var isVertical: Bool { self == .up || self == .down }
}

/// Moving a cursor across the canvas using the layout the user can actually
/// see, rather than a grid this file has assumed.
///
/// The three view modes place items differently enough that no single index
/// arithmetic describes all of them: the grid is uniform, the list is one
/// column, and masonry drops each item into whichever column is shortest, so
/// the item after another in sort order is routinely nowhere near it on
/// screen. Left and right therefore walk the sorted order — which is what
/// "next" means in a library, and which wraps rows the way Photos does — while
/// up and down are answered from measured frames, so a row means the row the
/// user is looking at.
///
/// Frames come from the canvas and cover only what has been laid out. When the
/// destination has not been measured — the row below is still off screen, or
/// the layout has not settled — movement falls back to stepping by the number
/// of columns, which is the right answer for a grid and a fair one elsewhere.
enum CanvasNavigation {

    /// Where `direction` leads from `origin`, or `nil` if it leads nowhere.
    static func destination(
        from origin: CanvasItemID?,
        direction: CanvasDirection,
        order: [CanvasItemID],
        frames: [CanvasItemID: CGRect]
    ) -> CanvasItemID? {
        guard !order.isEmpty else { return nil }

        // Nothing holds the cursor yet: the first key press enters the canvas
        // from the edge the key points away from.
        guard let origin, let index = order.firstIndex(of: origin) else {
            return direction == .up || direction == .left ? order.last : order.first
        }

        switch direction {
        case .left:
            return index > 0 ? order[index - 1] : nil
        case .right:
            return index + 1 < order.count ? order[index + 1] : nil
        case .up, .down:
            if let measured = nearest(from: origin, direction: direction, order: order, frames: frames) {
                return measured
            }
            return rowStep(from: index, direction: direction, order: order, frames: frames)
        }
    }

    /// The first or last item, for Home and End.
    static func edge(_ direction: CanvasDirection, in order: [CanvasItemID]) -> CanvasItemID? {
        direction == .up || direction == .left ? order.first : order.last
    }

    // MARK: Measured movement

    /// The nearest item that genuinely lies above or below the origin.
    ///
    /// Candidates are scored on how far they sit vertically plus how far their
    /// centre sits horizontally, the horizontal term weighted the heavier of
    /// the two. In a grid that picks the item directly below rather than the
    /// one below and across; in masonry, where a column is a run of items that
    /// share an x, it keeps movement inside the column the cursor is already
    /// in instead of drifting sideways down the canvas.
    private static func nearest(
        from origin: CanvasItemID,
        direction: CanvasDirection,
        order: [CanvasItemID],
        frames: [CanvasItemID: CGRect]
    ) -> CanvasItemID? {
        guard let start = frames[origin] else { return nil }

        // A row's items rarely share an exact top to the point, so a candidate
        // has to clear the origin by more than rounding before it counts as
        // being on another row at all.
        let tolerance: CGFloat = 1

        var best: (id: CanvasItemID, score: CGFloat)?
        for id in order where id != origin {
            guard let frame = frames[id] else { continue }
            let travel = frame.minY - start.minY
            let liesThatWay = direction == .down ? travel > tolerance : travel < -tolerance
            guard liesThatWay else { continue }

            let score = abs(travel) + abs(frame.midX - start.midX) * 2
            if best == nil || score < best!.score {
                best = (id, score)
            }
        }
        return best?.id
    }

    /// Movement by whole rows, for when the destination has not been measured.
    ///
    /// Stepping past either end lands on the item at that end rather than
    /// nowhere, so a press at the bottom row reaches the last item instead of
    /// appearing to do nothing.
    private static func rowStep(
        from index: Int,
        direction: CanvasDirection,
        order: [CanvasItemID],
        frames: [CanvasItemID: CGRect]
    ) -> CanvasItemID? {
        let stride = columnCount(in: frames)
        let target = direction == .down ? index + stride : index - stride
        if order.indices.contains(target) { return order[target] }
        if direction == .down { return index < order.count - 1 ? order.last : nil }
        return index > 0 ? order.first : nil
    }

    /// How many columns the canvas is currently drawing, read off the frames.
    ///
    /// Columns are counted by distinct leading edges rather than by dividing
    /// the width, so this holds for the grid, for masonry, and for the list —
    /// which has exactly one.
    static func columnCount(in frames: [CanvasItemID: CGRect]) -> Int {
        guard !frames.isEmpty else { return 1 }
        // Bucketed, because a fractional column width leaves items in the same
        // column disagreeing about their leading edge in the last decimal.
        let edges = Set(frames.values.map { ($0.minX / 4).rounded() })
        return max(1, edges.count)
    }
}

import CoreGraphics
import Foundation
import SwiftUI

/// Which way an arrow key is asking the cursor to go.
enum CanvasDirection: Hashable {
    case up, down, left, right

    var isVertical: Bool { self == .up || self == .down }
}

extension CanvasDirection {
    /// The arrow keys, named as directions.
    init?(_ key: KeyEquivalent) {
        switch key {
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        default: return nil
        }
    }
}

/// Moving a cursor across the canvas using the layout the user can actually
/// see, rather than a grid this file has assumed.
///
/// The three view modes place items differently enough that no single index
/// arithmetic describes all of them: the grid is uniform, the list is one
/// column, and masonry drops each item into whichever column is shortest, so
/// the item after another in sort order is routinely nowhere near it on
/// screen. Every arrow is therefore answered from measured frames. Horizontal
/// movement is confined to the current visual row. For vertical movement,
/// candidates in the same column win before diagonal candidates, and then the
/// nearest candidate wins, preserving movement into incomplete rows.
///
/// Frames come from the canvas and cover only what has been laid out. When the
/// destination has not been measured — the row below is still off screen, or
/// the layout has not settled — movement falls back to the canvas order. The
/// vertical fallback steps by the measured number of columns, while horizontal
/// movement steps by one.
///
/// Nothing here knows what it is moving between, so the same rules serve the
/// library canvas and Home's bands. Each names its own items; only the order
/// and the frames differ.
enum CanvasNavigation {

    /// Where `direction` leads from `origin`, or `nil` if it leads nowhere.
    static func destination<ID: Hashable>(
        from origin: ID?,
        direction: CanvasDirection,
        order: [ID],
        frames: [ID: CGRect]
    ) -> ID? {
        guard !order.isEmpty else { return nil }

        // Nothing holds the cursor yet: the first key press enters the canvas
        // from the edge the key points away from.
        guard let origin, let index = order.firstIndex(of: origin) else {
            return direction == .up || direction == .left ? order.last : order.first
        }

        if let measured = nearest(
            from: origin,
            direction: direction,
            order: order,
            frames: frames
        ) {
            return measured
        }

        switch direction {
        case .left:
            // A non-scrolling horizontal canvas has no unmeasured neighbour
            // beyond its visible edge. Once the origin is measured, no spatial
            // candidate means this really is the edge.
            guard frames[origin] == nil else { return nil }
            return index > 0 ? order[index - 1] : nil
        case .right:
            guard frames[origin] == nil else { return nil }
            return index + 1 < order.count ? order[index + 1] : nil
        case .up, .down:
            return rowStep(from: index, direction: direction, order: order, frames: frames)
        }
    }

    /// The first or last item, for Home and End.
    static func edge<ID>(_ direction: CanvasDirection, in order: [ID]) -> ID? {
        direction == .up || direction == .left ? order.first : order.last
    }

    // MARK: Measured movement

    /// The nearest measured item in the requested visual direction.
    ///
    /// A candidate whose perpendicular span overlaps the origin is in the same
    /// visual lane. Horizontal movement requires that overlap, so reaching a row
    /// edge cannot jump diagonally into another row. For vertical movement,
    /// lanes are considered before distance, so a close item in a neighbouring
    /// masonry column cannot steal Down from the next item in the current column.
    /// When a partial row leaves no item in that column, the smallest
    /// perpendicular gap supplies the natural diagonal neighbour.
    private static func nearest<ID: Hashable>(
        from origin: ID,
        direction: CanvasDirection,
        order: [ID],
        frames: [ID: CGRect]
    ) -> ID? {
        guard let start = frames[origin] else { return nil }

        let tolerance: CGFloat = 1
        var best: (id: ID, lane: Int, travel: CGFloat, crossGap: CGFloat, crossOffset: CGFloat, order: Int)?

        for (orderIndex, id) in order.enumerated() where id != origin {
            guard let frame = frames[id],
                  let metrics = metrics(
                    from: start,
                    to: frame,
                    direction: direction,
                    tolerance: tolerance
                  ),
                  direction.isVertical || metrics.isInLane
            else { continue }

            let candidate = (
                id: id,
                lane: metrics.isInLane ? 0 : 1,
                travel: metrics.travel,
                crossGap: metrics.crossGap,
                crossOffset: metrics.crossOffset,
                order: orderIndex
            )

            if best == nil || isBefore(candidate, best!) {
                best = candidate
            }
        }
        return best?.id
    }

    private static func metrics(
        from start: CGRect,
        to candidate: CGRect,
        direction: CanvasDirection,
        tolerance: CGFloat
    ) -> (isInLane: Bool, travel: CGFloat, crossGap: CGFloat, crossOffset: CGFloat)? {
        switch direction {
        case .up:
            let travel = start.minY - candidate.maxY
            guard travel >= -tolerance else { return nil }
            return (
                overlaps(start.minX...start.maxX, candidate.minX...candidate.maxX, tolerance: tolerance),
                max(0, travel),
                gap(start.minX...start.maxX, candidate.minX...candidate.maxX),
                abs(candidate.midX - start.midX)
            )
        case .down:
            let travel = candidate.minY - start.maxY
            guard travel >= -tolerance else { return nil }
            return (
                overlaps(start.minX...start.maxX, candidate.minX...candidate.maxX, tolerance: tolerance),
                max(0, travel),
                gap(start.minX...start.maxX, candidate.minX...candidate.maxX),
                abs(candidate.midX - start.midX)
            )
        case .left:
            let travel = start.minX - candidate.maxX
            guard travel >= -tolerance else { return nil }
            return (
                overlaps(start.minY...start.maxY, candidate.minY...candidate.maxY, tolerance: tolerance),
                max(0, travel),
                gap(start.minY...start.maxY, candidate.minY...candidate.maxY),
                abs(candidate.midY - start.midY)
            )
        case .right:
            let travel = candidate.minX - start.maxX
            guard travel >= -tolerance else { return nil }
            return (
                overlaps(start.minY...start.maxY, candidate.minY...candidate.maxY, tolerance: tolerance),
                max(0, travel),
                gap(start.minY...start.maxY, candidate.minY...candidate.maxY),
                abs(candidate.midY - start.midY)
            )
        }
    }

    private static func overlaps(
        _ first: ClosedRange<CGFloat>,
        _ second: ClosedRange<CGFloat>,
        tolerance: CGFloat
    ) -> Bool {
        first.lowerBound <= second.upperBound + tolerance
            && second.lowerBound <= first.upperBound + tolerance
    }

    private static func gap(
        _ first: ClosedRange<CGFloat>,
        _ second: ClosedRange<CGFloat>
    ) -> CGFloat {
        if first.overlaps(second) { return 0 }
        return first.upperBound < second.lowerBound
            ? second.lowerBound - first.upperBound
            : first.lowerBound - second.upperBound
    }

    private static func isBefore<ID>(
        _ lhs: (id: ID, lane: Int, travel: CGFloat, crossGap: CGFloat, crossOffset: CGFloat, order: Int),
        _ rhs: (id: ID, lane: Int, travel: CGFloat, crossGap: CGFloat, crossOffset: CGFloat, order: Int)
    ) -> Bool {
        if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
        if lhs.travel != rhs.travel { return lhs.travel < rhs.travel }
        if lhs.crossGap != rhs.crossGap { return lhs.crossGap < rhs.crossGap }
        if lhs.crossOffset != rhs.crossOffset { return lhs.crossOffset < rhs.crossOffset }
        return lhs.order < rhs.order
    }

    /// Movement by whole rows, for when the destination has not been measured.
    ///
    /// A row past either end is nowhere, and the key does nothing — which is
    /// what every other Mac list does at its edge. A short last row is not
    /// this case: it has been measured, so the nearest item in it answers
    /// before this does.
    private static func rowStep<ID: Hashable>(
        from index: Int,
        direction: CanvasDirection,
        order: [ID],
        frames: [ID: CGRect]
    ) -> ID? {
        let stride = columnCount(in: frames)
        let target = direction == .down ? index + stride : index - stride
        return order.indices.contains(target) ? order[target] : nil
    }

    /// How many columns the canvas is currently drawing, read off the frames.
    ///
    /// Columns are counted by distinct leading edges rather than by dividing
    /// the width, so this holds for the grid, for masonry, and for the list —
    /// which has exactly one.
    static func columnCount<ID: Hashable>(in frames: [ID: CGRect]) -> Int {
        guard !frames.isEmpty else { return 1 }
        // Bucketed, because a fractional column width leaves items in the same
        // column disagreeing about their leading edge in the last decimal.
        let edges = Set(frames.values.map { ($0.minX / 4).rounded() })
        return max(1, edges.count)
    }
}

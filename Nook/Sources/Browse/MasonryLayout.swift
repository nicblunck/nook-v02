import SwiftUI

/// A column layout that lets each item keep its own height.
///
/// Items are placed into whichever column is currently shortest, which keeps
/// the bottom edge roughly even without imposing a uniform aspect ratio — the
/// point of masonry for a library of mixed screenshots, posters and stills.
struct MasonryLayout: Layout {
    var minimumColumnWidth: CGFloat = 160
    var spacing: CGFloat = 16
    /// Invalidates cached item heights when a presentation preference changes
    /// whether captions participate in the masonry layout.
    var contentRevision: Int = 0

    /// The arrangement last worked out, and the width it was worked out for.
    ///
    /// Measuring the wall and placing it are two passes over the same numbers,
    /// and every pass measures every tile — so without this, opening the
    /// inspector measures the whole wall twice for each frame of the animation.
    /// SwiftUI rebuilds the cache whenever subviews change. The explicit
    /// content revision below also invalidates it when a caption setting adds
    /// or removes measured height without changing the item count.
    struct Cache {
        var width: CGFloat?
        var contentRevision: Int?
        var resolved: Resolved?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = layoutWidth(for: proposal)
        #if os(iOS)
        // A loaded thumbnail can correct stale or absent stored dimensions.
        // Remeasure on iOS so that local card state can reflow the wall; there
        // is no animated inspector resize here, which is what the macOS cache
        // primarily protects.
        let layout = arrange(width: width, subviews: subviews)
        cache.width = width
        cache.contentRevision = contentRevision
        cache.resolved = layout
        #else
        let layout = resolve(width: width, subviews: subviews, cache: &cache)
        #endif
        return CGSize(width: width, height: layout.columnHeights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let layout = resolve(width: bounds.width, subviews: subviews, cache: &cache)
        for (index, subview) in subviews.enumerated() {
            let placement = layout.placements[index]
            subview.place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                proposal: ProposedViewSize(width: layout.columnWidth, height: placement.height)
            )
        }
    }

    /// A scroll view can ask what the wall wants before it has a width to offer
    /// it, and can offer an unbounded one. Neither is a width to lay out
    /// against, so both fall back to the narrowest wall there is.
    private func layoutWidth(for proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return minimumColumnWidth
        }
        return width
    }

    // MARK: Placement

    struct Resolved {
        var columnWidth: CGFloat
        var columnHeights: [CGFloat]
        var placements: [(x: CGFloat, y: CGFloat, height: CGFloat)]
    }

    private func resolve(width: CGFloat, subviews: Subviews, cache: inout Cache) -> Resolved {
        // The count is checked as well as the width: SwiftUI rebuilds the
        // cache when the subviews change, and this is what holds that promise
        // to a placement rather than an assumption.
        if let resolved = cache.resolved,
           cache.width == width,
           cache.contentRevision == contentRevision,
           resolved.placements.count == subviews.count {
            return resolved
        }
        let resolved = arrange(width: width, subviews: subviews)
        cache.width = width
        cache.contentRevision = contentRevision
        cache.resolved = resolved
        return resolved
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> Resolved {
        let columnCount = max(1, Int((width + spacing) / (minimumColumnWidth + spacing)))
        let columnWidth = (width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)

        var heights = [CGFloat](repeating: 0, count: columnCount)
        var placements: [(x: CGFloat, y: CGFloat, height: CGFloat)] = []
        placements.reserveCapacity(subviews.count)

        for subview in subviews {
            let height = subview.sizeThatFits(
                ProposedViewSize(width: columnWidth, height: nil)
            ).height

            let column = heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
            let x = CGFloat(column) * (columnWidth + spacing)
            let y = heights[column]
            placements.append((x: x, y: y, height: height))
            heights[column] = y + height + spacing
        }

        // Trim the trailing gap the last row would otherwise leave.
        let trimmed = heights.map { max(0, $0 - spacing) }
        return Resolved(columnWidth: columnWidth,
                        columnHeights: trimmed,
                        placements: placements)
    }
}

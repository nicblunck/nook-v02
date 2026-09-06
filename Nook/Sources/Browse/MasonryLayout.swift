import SwiftUI

/// A column layout that lets each item keep its own height.
///
/// Items are placed into whichever column is currently shortest, which keeps
/// the bottom edge roughly even without imposing a uniform aspect ratio — the
/// point of masonry for a library of mixed screenshots, posters and stills.
struct MasonryLayout: Layout {
    var minimumColumnWidth: CGFloat = 160
    var spacing: CGFloat = 16

    struct Cache {
        var columnCount: Int = 1
        var heights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? minimumColumnWidth
        let layout = resolve(width: width, subviews: subviews)
        cache.columnCount = layout.columnCount
        cache.heights = layout.columnHeights
        return CGSize(width: width, height: layout.columnHeights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let layout = resolve(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let placement = layout.placements[index]
            subview.place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                proposal: ProposedViewSize(width: layout.columnWidth, height: placement.height)
            )
        }
    }

    // MARK: Placement

    private struct Resolved {
        var columnCount: Int
        var columnWidth: CGFloat
        var columnHeights: [CGFloat]
        var placements: [(x: CGFloat, y: CGFloat, height: CGFloat)]
    }

    private func resolve(width: CGFloat, subviews: Subviews) -> Resolved {
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
        return Resolved(columnCount: columnCount,
                        columnWidth: columnWidth,
                        columnHeights: trimmed,
                        placements: placements)
    }
}

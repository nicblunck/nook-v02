import SwiftUI
import NookLibrary

/// An entity's identity marker: its emoji if it has one, otherwise its symbol
/// in its colour, otherwise the system default for that kind of entity.
///
/// One view for every surface — sidebar, canvas, pickers, pills — so a folder
/// looks like itself wherever it appears.
///
/// The icon is decorative. It appears only beside the entity's own name, and
/// spoken aloud it would prefix every folder with the name of its emoji or
/// symbol, so it is hidden from VoiceOver rather than announced twice.
struct EntityIcon: View {
    let appearance: EntityAppearance
    let fallbackSymbol: String
    var size: CGFloat = 15

    /// Text scales with the reader's type size, so an icon sitting on the same
    /// line has to scale with it or fall out of proportion.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    var body: some View {
        Group {
            if let emoji = appearance.emoji {
                Text(emoji).font(.system(size: scaledSize))
            } else {
                Image(systemName: appearance.symbolName ?? fallbackSymbol)
                    .font(.system(size: scaledSize))
                    .foregroundStyle(tint)
            }
        }
        .accessibilityHidden(true)
    }

    private var scaledSize: CGFloat { size * typeScale }

    private var tint: Color {
        Color(hex: appearance.colorHex) ?? .accentColor
    }
}

/// A tag's name with its identity marker: a custom emoji or SF Symbol when
/// one has been chosen, otherwise the familiar `#` prefix.
struct TagLabel: View {
    let tag: TagSnapshot
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            if let emoji = tag.appearance.emoji {
                Text(emoji)
            } else if let symbol = tag.appearance.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: size - 1, weight: .semibold))
            }

            if tag.appearance.emoji != nil || tag.appearance.symbolName != nil {
                Text(tag.name)
            } else {
                Text("#\(tag.name)")
            }
        }
        .accessibilityLabel(tag.name)
    }
}

/// The pill used wherever a tag is shown as a label rather than as a row.
/// Optional actions let Get Info keep its remove affordance inside the pill,
/// while the sidebar can wrap the same visual in its navigation button.
struct TagPill: View {
    let tag: TagSnapshot
    var isSelected = false
    var onSelect: (() -> Void)?
    var onRemove: (() -> Void)?

    private var tint: Color {
        Color(hex: tag.appearance.colorHex) ?? .accentColor
    }

    var body: some View {
        HStack(spacing: 3) {
            if let onSelect {
                Button(action: onSelect) {
                    TagLabel(tag: tag)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                TagLabel(tag: tag)
            }

            if let onRemove {
                Button("Remove", systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 7, weight: .bold))
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(tag.name)")
            }
        }
        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? Color.white : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.16)),
            in: Capsule()
        )
        .contentShape(Capsule())
    }
}

/// A wrapping layout for pills whose widths are determined by their labels.
/// A grid cannot do this without either wasting space or truncating names.
struct TagFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height + spacing }
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: max(0, height - spacing))
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }

        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

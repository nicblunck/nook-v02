import SwiftUI
import NookLibrary

/// An item in the icon grid: the picture at its own proportions, its name
/// centred underneath.
///
/// The arrangement is the Finder's, and so is the highlight — a pill behind
/// the label and a tint behind the icon, rather than a card drawn around the
/// whole item. A wall of these reads as pictures with names, not as tiles.
///
/// That highlight is the only state this view draws. Where the other layouts
/// separate the keyboard's position from the selection by ringing one and
/// filling the other, a grid of named icons is the one place the Finder does
/// not: the item the keyboard is on is lit the same way a selected one is.
struct ObjectCard: View {
    let object: ObjectSnapshot
    let isSelected: Bool
    /// Whether the keyboard is resting here, which lights the item without
    /// claiming it has been selected.
    let isCursor: Bool
    /// The size the user has asked for, as a multiple of the natural one.
    let scale: Double

    /// The icon occupies a square, whatever shape the picture in it is. That
    /// is what lets the highlight be a square too, and what keeps a row of
    /// portraits and landscapes sitting on one baseline.
    ///
    /// The label is deliberately left out of the resizing, as the Finder
    /// leaves it out: names stay readable at every size, and it is the
    /// pictures the user is asking to see more or less of.
    @ScaledMetric(relativeTo: .body) private var baseIconSize: CGFloat = 64
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    var body: some View {
        VStack(spacing: 3) {
            icon
            label
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .contentShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.title)
        // The badges below are drawn without labels, so the spoken caption is
        // what carries locked and favourite to a reader who cannot see them.
        .accessibilityValue(Format.spokenCaption(for: object))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The picture keeps its own proportions and grows until it meets the
    /// square on whichever side runs out first, so a portrait ends up narrow
    /// and a landscape wide while both fill the space they are given.
    private var icon: some View {
        ThumbnailView(object: object, maximumSize: thumbnailResolution)
            .aspectRatio(object.aspectRatio ?? 1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 4 * min(scale, 2)))
            .overlay(alignment: .topTrailing) { badges }
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .frame(width: iconSize, height: iconSize)
            .padding(5)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(highlight.opacity(0.16))
                    .opacity(isHighlighted ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
    }

    private var label: some View {
        VStack(spacing: 0) {
            Text(object.title)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(isLabelInverted ? Color.white : Color.primary)
            Text(Format.caption(for: object))
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isLabelInverted ? Color.white.opacity(0.85) : Color.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(highlight)
                .opacity(isHighlighted ? 1 : 0)
        }
        .padding(.horizontal, 4)
    }

    /// Privacy and state indicators sit on the icon without revealing anything
    /// the object is protecting.
    private var badges: some View {
        HStack(spacing: 4) {
            if object.isLocked { badge("lock.fill") }
            if object.isFavorite { badge("star.fill") }
        }
        .padding(3)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .semibold))
            .padding(3)
            .background(.regularMaterial, in: .circle)
    }

    /// A window that is not the key one dims its selection to grey, the way
    /// every other list on the platform does: the highlight says "these are
    /// the ones", not "the keyboard is here".
    private var isWindowActive: Bool {
        #if os(macOS)
        controlActiveState != .inactive
        #else
        true
        #endif
    }

    private var highlight: Color {
        isWindowActive ? .accentColor : Color.secondary.opacity(0.32)
    }

    private var iconSize: CGFloat { baseIconSize * scale }

    /// Enough pixels for the size actually being drawn, so growing the icons
    /// sharpens them rather than magnifying what was fetched for a small one.
    private var thumbnailResolution: CGFloat { min(1024, max(256, iconSize * 3)) }

    private var isHighlighted: Bool { isSelected || isCursor }

    private var isLabelInverted: Bool { isHighlighted && isWindowActive }
}

/// A folder as it appears inline in the canvas, arranged like its neighbours.
struct FolderCard: View {
    let folder: FolderSnapshot
    var peeks: [ObjectSnapshot] = []
    @State private var isHovered = false
    /// Drawn lit in the layouts that have no cursor ring of their own.
    var isHighlighted: Bool = false
    var scale: Double = 1
    let onOpen: () -> Void

    @ScaledMetric(relativeTo: .body) private var baseIconSize: CGFloat = 64
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    var body: some View {
        VStack(spacing: 3) {
            FolderPeekIcon(folder: folder, objects: peeks, isOpen: isHovered, width: iconSize)
                .frame(width: iconSize, height: iconSize)
                .padding(5)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(highlight.opacity(0.16))
                        .opacity(isHighlighted ? 1 : 0)
                }
                .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                Text(folder.name)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(isLabelInverted ? Color.white : Color.primary)
                Text(itemCountDescription)
                    .font(.caption)
                    .foregroundStyle(isLabelInverted ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(highlight)
                    .opacity(isHighlighted ? 1 : 0)
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .contentShape(.rect(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .itemClick { onOpen() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.name)")
        // An explicit label replaces the combined children, so what the card
        // shows about its contents has to be restated as a value.
        .accessibilityValue(spokenItemCount)
        .accessibilityHint("Opens the folder")
        .accessibilityAddTraits(.isButton)
    }

    private var countParts: [String] {
        var parts: [String] = []
        if folder.subfolderCount > 0 { parts.append(Format.folderCount(folder.subfolderCount)) }
        parts.append(Format.itemCount(folder.objectCount))
        return parts
    }

    private var itemCountDescription: String {
        countParts.joined(separator: " · ")
    }

    private var spokenItemCount: String {
        var parts = countParts
        if folder.isLocked { parts.append("Locked") }
        return parts.joined(separator: ", ")
    }

    private var iconSize: CGFloat { baseIconSize * scale }

    private var isWindowActive: Bool {
        #if os(macOS)
        controlActiveState != .inactive
        #else
        true
        #endif
    }

    private var highlight: Color {
        isWindowActive ? .accentColor : Color.secondary.opacity(0.32)
    }

    private var isLabelInverted: Bool { isHighlighted && isWindowActive }
}

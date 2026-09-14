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
        .motionAware(NookMotion.interaction, value: isHighlighted)
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
            .frame(width: iconImageSize.width, height: iconImageSize.height)
            .clipShape(.rect(cornerRadius: 4 * min(scale, 2)))
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
            titleText
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

    /// Privacy and Favorite ride along with the name rather than the picture,
    /// so the icon itself never carries a mark of what the object is doing.
    private var titleText: Text {
        switch (object.isHidden, object.isLocked, object.isFavorite) {
        case (true, true, true):
            Text("\(object.title) \(Image(systemName: "eye.slash")) \(Image(systemName: "lock.fill")) \(Image(systemName: "star.fill"))")
        case (true, true, false):
            Text("\(object.title) \(Image(systemName: "eye.slash")) \(Image(systemName: "lock.fill"))")
        case (true, false, true):
            Text("\(object.title) \(Image(systemName: "eye.slash")) \(Image(systemName: "star.fill"))")
        case (true, false, false):
            Text("\(object.title) \(Image(systemName: "eye.slash"))")
        case (false, true, true):
            Text("\(object.title) \(Image(systemName: "lock.fill")) \(Image(systemName: "star.fill"))")
        case (false, true, false):
            Text("\(object.title) \(Image(systemName: "lock.fill"))")
        case (false, false, true):
            Text("\(object.title) \(Image(systemName: "star.fill"))")
        case (false, false, false):
            Text(object.title)
        }
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

    /// Fits the object's native proportions into the icon square with exactly
    /// one constrained edge. This avoids relying on nested aspect-ratio
    /// modifiers, whose proposals can compound when a Quick Look thumbnail
    /// already contains its own fitted canvas.
    private var iconImageSize: CGSize {
        let ratio = CGFloat(object.aspectRatio ?? 1)
        guard ratio.isFinite, ratio > 0 else {
            return CGSize(width: iconSize, height: iconSize)
        }
        if ratio >= 1 {
            return CGSize(width: iconSize, height: iconSize / ratio)
        }
        return CGSize(width: iconSize * ratio, height: iconSize)
    }

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
    let isSelected: Bool
    let isCursor: Bool
    var scale: Double = 1
    /// A single click is another way of saying the keyboard belongs to the
    /// canvas and should rest here, the same thing clicking an object says.
    var select: (EventModifiers) -> Void = { _ in }
    let onOpen: () -> Void

    @ScaledMetric(relativeTo: .body) private var baseIconSize: CGFloat = 64
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    /// A selected folder remains open after the pointer leaves. Keyboard
    /// navigation opens the folder under the cursor as well. There is no
    /// pointer on iOS, so there a folder stays open whenever it has contents.
    private var isOpen: Bool {
        #if os(iOS)
        hasContent
        #else
        isHovered || isSelected || isCursor
        #endif
    }

    private var hasContent: Bool { folder.objectCount > 0 || folder.subfolderCount > 0 }

    var body: some View {
        VStack(spacing: 3) {
            FolderPeekIcon(folder: folder, objects: peeks, isOpen: isOpen, width: iconSize)
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
                Text(Format.caption(for: folder))
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
        .itemClick(select: select, open: onOpen)
        .motionAware(NookMotion.interaction, value: isOpen)
        .motionAware(NookMotion.interaction, value: isHighlighted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.name)")
        // An explicit label replaces the combined children, so what the card
        // shows about its contents has to be restated as a value.
        .accessibilityValue(Format.spokenCaption(for: folder))
        .accessibilityHint("Opens the folder")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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

    private var isHighlighted: Bool { isSelected || isCursor }

    private var isLabelInverted: Bool { isHighlighted && isWindowActive }
}

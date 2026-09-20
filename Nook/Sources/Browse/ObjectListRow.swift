import SwiftUI
import NookLibrary

/// A dense row for the list view: enough metadata to scan a large mixed
/// library without opening anything.
struct ObjectListRow: View {
    let object: ObjectSnapshot
    let isSelected: Bool

    /// The metadata columns are sized to their content, so they have to grow
    /// with the reader's type size or the text inside them truncates first.
    @ScaledMetric(relativeTo: .body) private var thumbnailSize: CGFloat = 38
    @ScaledMetric(relativeTo: .caption) private var kindWidth: CGFloat = 74
    @ScaledMetric(relativeTo: .caption) private var sizeWidth: CGFloat = 68
    @ScaledMetric(relativeTo: .caption) private var dateWidth: CGFloat = 84

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(object: object, maximumSize: 128)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(.rect(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 1) {
                titleText
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let filename = object.originalFilename, filename != object.title {
                    Text(filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Text(object.kind.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: kindWidth, alignment: .leading)

            Text(Format.bytes(object.byteSize) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: sizeWidth, alignment: .trailing)

            Text(object.dateAdded.formatted(date: .numeric, time: .omitted))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: dateWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear))
        }
        .contentShape(.rect)
        .nookMotion(.interaction, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.title)
        .accessibilityValue(Format.spokenCaption(for: object))
        // Selection is drawn as a tinted background, which is not something
        // VoiceOver can see.
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Privacy and Favorite ride along with the name rather than sitting in
    /// their own column, so they read as properties of the item, not as
    /// another piece of metadata alongside kind, size, and date.
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
}

/// A folder row in the list view.
struct FolderListRow: View {
    let folder: FolderSnapshot
    let isSelected: Bool

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 38

    var body: some View {
        HStack(spacing: 12) {
            EntityIcon(appearance: folder.appearance, fallbackSymbol: "folder.fill", size: 20)
                .frame(width: iconSize, height: iconSize)

            Text(folder.name).lineLimit(1)
            Spacer(minLength: 8)
            Text(Format.itemCount(folder.objectCount))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear))
        }
        .contentShape(.rect)
        .nookMotion(.interaction, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.name)")
        .accessibilityValue(folderValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var folderValue: String {
        var parts = [Format.itemCount(folder.objectCount)]
        if folder.isHidden { parts.append("Hidden") }
        if folder.isLocked { parts.append("Locked") }
        return parts.joined(separator: ", ")
    }
}

private enum MasonryCaptionPresentation: Equatable {
    case overlay
    case attached
    case hidden
}

private extension MasonryCaptionDisplay {
    var masonryPresentation: MasonryCaptionPresentation {
        #if os(iOS)
        self == .hidden ? .hidden : .attached
        #else
        switch self {
        case .automatic: .overlay
        case .always: .attached
        case .hidden: .hidden
        }
        #endif
    }
}

/// Gives object and folder cards one caption policy while keeping each visual
/// section as its own view and invalidation boundary.
private struct MasonryCaptionLayout<Media: View, Caption: View>: View {
    let presentation: MasonryCaptionPresentation
    let showsOverlayCaption: Bool
    let media: Media
    let caption: Caption

    var body: some View {
        switch presentation {
        case .overlay:
            media.overlay(alignment: .bottom) {
                caption.opacity(showsOverlayCaption ? 1 : 0)
            }
        case .attached:
            VStack(spacing: 0) {
                media
                caption
            }
        case .hidden:
            media
        }
    }
}

/// A masonry tile: the picture, full-bleed, at its own proportions.
///
/// On macOS the name arrives under the pointer, on a color-matched bar whose
/// black-or-white text stays legible over any photograph. Touch devices have no
/// hover state, so there the caption remains visible in an attached section
/// below the picture, leaving the complete picture unobscured.
///
/// The two states a tile can be in are told apart by where they sit rather
/// than by colour: selection is a grey mat laid behind the tile, and the
/// keyboard's own position is the accent ring the canvas draws inside that
/// mat. Neither touches the picture, which is the thing being looked at, and
/// a selection of many tiles is legible without the cursor moving.
///
/// The caption follows the keyboard as well as the pointer. Arrowing across a
/// wall of pictures is the same act as running the pointer over it, and it
/// would be a poor trade if the names were readable only to a mouse.
struct ObjectMasonryCard: View {
    let object: ObjectSnapshot
    let isSelected: Bool
    let isCursor: Bool
    let captionDisplay: MasonryCaptionDisplay
    let showsTypeLabel: Bool
    /// Only the picture's resolution depends on this. The tile's width is the
    /// column's, which the layout has already sized.
    let scale: Double

    @State private var isHovering = false
    @State private var thumbnailAppearance: ThumbnailAppearance?
    #if os(iOS)
    @State private var thumbnailAspectRatio: Double?
    #endif

    private let radius: CGFloat = 14
    /// How far the mat reaches past the picture. Wider than the cursor ring's
    /// standoff, so the ring lands on the mat rather than beyond it.
    private let selectionInset: CGFloat = 8

    var body: some View {
        MasonryCaptionLayout(
            presentation: captionDisplay.masonryPresentation,
            showsOverlayCaption: isHovering || isCursor,
            media: ObjectMasonryMedia(
                object: object,
                aspectRatio: displayAspectRatio,
                maximumThumbnailSize: min(1536, max(512, 420 * scale)),
                onAspectRatioChange: thumbnailAspectRatioHandler,
                appearance: thumbnailAppearance,
                onAppearanceChange: { thumbnailAppearance = $0 },
                showsTypeLabel: showsTypeLabel
            ),
            caption: ObjectMasonryCaption(
                object: object,
                color: thumbnailAppearance?.predominantColor ?? .neutral
            )
        )
        .clipShape(.rect(cornerRadius: radius))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        // Behind the tile, and behind its shadow, so a selected picture is
        // shown exactly as an unselected one is.
        .background {
            RoundedRectangle(cornerRadius: radius + selectionInset)
                .fill(.secondary)
                .opacity(isSelected ? 0.35 : 0)
                .padding(-selectionInset)
        }
        .contentShape(.rect(cornerRadius: radius))
        .onHover { isHovering = $0 }
        .nookMotion(.interaction, value: isHovering || isCursor)
        .nookMotion(.interaction, value: isSelected)
        // A change of caption setting is deliberately not animated here.
        // It changes every tile's height, and the masonry wall resolves its
        // placements from a cache that a height still in flight cannot
        // invalidate — so animating it leaves each tile growing into the one
        // placed below. The wall re-places in a single frame instead, which
        // is the one arrangement in which nothing overlaps.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.title)
        // macOS only draws the caption where the pointer or keyboard is,
        // so everything it says has to reach a reader who never sees it.
        .accessibilityValue(Format.spokenCaption(for: object))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var thumbnailAspectRatioHandler: ((Double) -> Void)? {
        #if os(iOS)
        updateThumbnailAspectRatio
        #else
        nil
        #endif
    }

    private var displayAspectRatio: Double {
        #if os(iOS)
        thumbnailAspectRatio ?? object.aspectRatio ?? 1
        #else
        object.aspectRatio ?? 1
        #endif
    }

    #if os(iOS)
    private func updateThumbnailAspectRatio(_ ratio: Double) {
        guard ratio.isFinite, ratio > 0 else { return }
        guard abs(ratio - displayAspectRatio) > 0.001 else { return }
        let storedRatio = object.aspectRatio ?? 1
        thumbnailAspectRatio = abs(ratio - storedRatio) > 0.001 ? ratio : nil
    }
    #endif
}

/// The media region controls its own aspect-ratio height so the caption can
/// add height below it without cropping or covering any part of the picture.
private struct ObjectMasonryMedia: View {
    let object: ObjectSnapshot
    let aspectRatio: Double
    let maximumThumbnailSize: CGFloat
    let onAspectRatioChange: ((Double) -> Void)?
    let appearance: ThumbnailAppearance?
    let onAppearanceChange: (ThumbnailAppearance?) -> Void
    let showsTypeLabel: Bool

    var body: some View {
        // The shape, not the picture, decides the media region's size: a plain
        // rectangle obeys an aspect ratio exactly, while the picture fills the
        // matching box. An item without stored dimensions starts square until
        // its thumbnail reports its displayed proportions.
        Rectangle()
            .fill(appearance?.hasTransparentBackground == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clear))
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                ThumbnailView(
                    object: object,
                    maximumSize: maximumThumbnailSize,
                    onAspectRatioChange: onAspectRatioChange,
                    onAppearanceChange: onAppearanceChange
                )
                .clipped()
            }
            // An overlay receives the media region's size without contributing
            // its own ideal width, so a long URL cannot widen its masonry column.
            .overlay(alignment: .topTrailing) {
                ObjectMasonryBadges(object: object, showsTypeLabel: showsTypeLabel)
            }
    }
}

private struct ObjectMasonryCaption: View {
    let object: ObjectSnapshot
    let color: ThumbnailColor

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(object.title)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(Format.caption(for: object))
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(color.contrastingTextColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background { MasonryCaptionGlass(color: color) }
    }
}

/// A translucent predominant-color wash over system material. The final light
/// or dark veil reinforces the same contrast direction chosen for the text.
private struct MasonryCaptionGlass: View {
    let color: ThumbnailColor

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Rectangle().fill(color.color.opacity(0.78))
            Rectangle().fill(
                color.usesDarkText
                    ? Color.white.opacity(0.08)
                    : Color.black.opacity(0.08)
            )
        }
        .allowsHitTesting(false)
    }
}

private struct ObjectMasonryBadges: View {
    let object: ObjectSnapshot
    let showsTypeLabel: Bool

    var body: some View {
        if showsTypeLabel || object.isHidden || object.isLocked || object.isFavorite {
            HStack(spacing: 4) {
                if object.isHidden { badge("eye.slash") }
                if object.isLocked { badge("lock.fill") }
                if object.isFavorite { badge("star.fill") }
                if showsTypeLabel { badge(object.kind.symbolName) }
            }
            .padding(8)
        }
    }

    /// State and type symbols sit over the picture itself, so they remain
    /// readable independently of the caption presentation.
    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.semibold))
            .padding(5)
            .background(.regularMaterial, in: .circle)
    }
}

/// A masonry tile for a folder.
///
/// A photograph's tile takes the picture's own proportions; a folder has none
/// of its own to take, so its tile is always a square — and carries the
/// folder's own colour, the way every other drawing of a folder in the app
/// does, rather than sitting on the wall as a blank frame around a small icon.
struct FolderMasonryCard: View {
    let folder: FolderSnapshot
    var peeks: [ObjectSnapshot] = []
    let isSelected: Bool
    let isCursor: Bool
    let captionDisplay: MasonryCaptionDisplay
    var scale: Double = 1
    /// A single click is another way of saying the keyboard belongs to the
    /// canvas and should rest here, the same thing clicking an object says.
    var select: (EventModifiers) -> Void = { _ in }
    let onOpen: () -> Void

    @State private var isHovering = false

    /// A selected folder stays open after the pointer leaves, while keyboard
    /// navigation also opens the folder under the cursor.
    private var isOpen: Bool { isHovering || isSelected || isCursor }

    /// There is no pointer on iOS, so the flap itself follows content
    /// instead of focus: open whenever there is something inside, shut when
    /// there isn't.
    private var iconIsOpen: Bool {
        #if os(iOS)
        folder.objectCount > 0 || folder.subfolderCount > 0
        #else
        isOpen
        #endif
    }

    private let radius: CGFloat = 14
    private let selectionInset: CGFloat = 8

    var body: some View {
        MasonryCaptionLayout(
            presentation: captionDisplay.masonryPresentation,
            showsOverlayCaption: isOpen,
            media: FolderMasonryMedia(folder: folder, peeks: peeks, isOpen: iconIsOpen),
            caption: FolderMasonryCaption(
                folder: folder,
                color: ThumbnailColor(hex: folder.appearance.colorHex) ?? .neutral
            )
        )
        .clipShape(.rect(cornerRadius: radius))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .background {
            RoundedRectangle(cornerRadius: radius + selectionInset)
                .fill(.secondary)
                .opacity(isSelected ? 0.35 : 0)
                .padding(-selectionInset)
        }
        .contentShape(.rect(cornerRadius: radius))
        .onHover { isHovering = $0 }
        .itemClick(select: select, open: onOpen)
        .nookMotion(.interaction, value: isOpen)
        .nookMotion(.interaction, value: isSelected)
        // A change of caption setting is deliberately not animated here.
        // It changes every tile's height, and the masonry wall resolves its
        // placements from a cache that a height still in flight cannot
        // invalidate — so animating it leaves each tile growing into the one
        // placed below. The wall re-places in a single frame instead, which
        // is the one arrangement in which nothing overlaps.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.name)")
        .accessibilityValue(Format.spokenCaption(for: folder))
        .accessibilityHint("Opens the folder")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct FolderMasonryMedia: View {
    let folder: FolderSnapshot
    let peeks: [ObjectSnapshot]
    let isOpen: Bool

    private var tint: Color { Color(hex: folder.appearance.colorHex) ?? .accentColor }

    var body: some View {
        Rectangle()
            .fill(tint.opacity(0.18))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    FolderPeekIcon(folder: folder, objects: peeks, isOpen: isOpen,
                                   width: proxy.size.width * 0.72)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
    }
}

private struct FolderMasonryCaption: View {
    let folder: FolderSnapshot
    let color: ThumbnailColor

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            titleText
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(Format.caption(for: folder))
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(color.contrastingTextColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background { MasonryCaptionGlass(color: color) }
    }

    /// Locked rides along with the name in the caption bar, rather than
    /// floating over the icon, the way it does on the object tile beside it.
    private var titleText: Text {
        folder.isLocked
            ? Text("\(folder.name) \(Image(systemName: "lock.fill"))")
            : Text(folder.name)
    }
}

import SwiftUI
import NookLibrary

// MARK: The list card

/// The metrics every list row is built to, object and folder alike, so a
/// mixed list sits on one rhythm rather than on two.
private enum ListCard {
    static let cornerRadius: CGFloat = 14
    static let thumbnailRadius: CGFloat = 8
    static let padding: CGFloat = 10
    static let contentSpacing: CGFloat = 12
}

/// The card every list row is drawn on.
///
/// A list of these is a stack of cards rather than a table: each row carries
/// its own surface, which is what lets the thumbnail, the name and the
/// metadata sit in one block that stays whole at a phone's width instead of
/// spreading into columns that squeeze the name to nothing.
///
/// The surface is glass, laid beneath the row rather than around it: content
/// wrapped in `glassEffect` is composited into the glass so the system can
/// tint it, which would soften the thumbnail.
///
/// Selection tints the surface; the keyboard cursor is the ring the gallery
/// draws around it, so a row can show both at once.
private struct ListCardBackground: View {
    let isSelected: Bool

    var body: some View {
        Color.clear
            .glassEffect(.regular, in: .rect(cornerRadius: ListCard.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ListCard.cornerRadius)
                    .fill(Color.accentColor)
                    .opacity(isSelected ? 0.18 : 0)
            }
    }
}

/// A small circular mark on the metadata line: the object's type, and
/// whatever state it is in.
///
/// Filled rather than material, because a material circle laid on the card's
/// own fill would all but disappear — unlike the badges over a masonry
/// picture, which have a photograph to stand out against.
private struct ListRowBadge: View {
    let symbolName: String
    var tint: Color?

    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 20
    /// How far the badge's centre sits above the line's baseline — about
    /// half a capital's height, so a circle carrying no text of its own
    /// still rides the line the way the words beside it do.
    @ScaledMetric(relativeTo: .subheadline) private var baselineRise: CGFloat = 5

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: diameter * 0.5, weight: .semibold))
            .foregroundStyle(tint ?? .secondary)
            .frame(width: diameter, height: diameter)
            .background((tint ?? .secondary).opacity(0.16), in: .circle)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + baselineRise }
    }
}

/// The tags on a row, as many of them as the width in hand will take.
///
/// Rather than pick a number for the phone and another for the Mac, every
/// arrangement is offered in turn and the widest one that fits is used — so
/// the same row shows three tags in a wide window, one and a count in a
/// narrow one, and a bare count on a phone, without measuring anything.
private struct ListRowTags: View {
    let tags: [TagSnapshot]

    var body: some View {
        if !tags.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(candidateCounts, id: \.self) { shown in
                    strip(showing: shown)
                }
                overflow(count: tags.count)
            }
            .accessibilityHidden(true)
        }
    }

    /// Every count from all of them down to one, so the fit is found by
    /// giving up one tag at a time.
    private var candidateCounts: [Int] {
        Array(stride(from: min(tags.count, 3), through: 1, by: -1))
    }

    @ViewBuilder
    private func strip(showing shown: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(tags.prefix(shown)) { tag in
                TagPill(tag: tag)
            }
            if tags.count > shown {
                overflow(count: tags.count - shown)
            }
        }
        .fixedSize()
    }

    private func overflow(count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
            .fixedSize()
    }
}

// MARK: Rows

/// A row in the list view: a horizontal card carrying the picture, the name,
/// what the object is and what it is tagged with.
///
/// The metadata that used to sit in fixed columns to the right now runs
/// underneath the name, where it can be as long or as short as the object
/// requires. Nothing in the row has a width of its own any more, so the name
/// keeps whatever the card has left rather than what three columns allow.
struct ObjectListRow: View {
    let object: ObjectSnapshot
    let isSelected: Bool

    @ScaledMetric(relativeTo: .body) private var thumbnailSize: CGFloat = 56

    var body: some View {
        HStack(spacing: ListCard.contentSpacing) {
            ThumbnailView(object: object, maximumSize: 256)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(.rect(cornerRadius: ListCard.thumbnailRadius))

            VStack(alignment: .leading, spacing: 4) {
                Text(object.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // One baseline runs the whole width of this line: the
                // metadata, the marks after it and the tags at the end all
                // sit on it, so the line reads as a sentence about the
                // object rather than as three things stacked side by side.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.listSubtitle(for: object))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    ListRowBadge(symbolName: object.kind.symbolName)
                    if object.isFavorite {
                        ListRowBadge(symbolName: "star.fill", tint: .yellow)
                    }
                    if object.isHidden {
                        ListRowBadge(symbolName: "eye.slash")
                    }

                    Spacer(minLength: 8)

                    ListRowTags(tags: object.tags)
                }
            }
        }
        .padding(ListCard.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ListCardBackground(isSelected: isSelected) }
        .contentShape(.rect(cornerRadius: ListCard.cornerRadius))
        .motionAware(NookMotion.interaction, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.title)
        .accessibilityValue(Format.spokenListRow(for: object))
        // Selection is drawn as a tinted background, which is not something
        // VoiceOver can see.
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A folder row in the list view.
///
/// Built to the same card as an object's so a list of both reads as one
/// list. What a photograph gives to its thumbnail, a folder gives to its own
/// icon and colour — drawn in a tinted well of the same size, so the names
/// below still start on one line down the left edge.
struct FolderListRow: View {
    let folder: FolderSnapshot
    let isSelected: Bool

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 56

    private var tint: Color { Color(hex: folder.appearance.colorHex) ?? .accentColor }

    var body: some View {
        HStack(spacing: ListCard.contentSpacing) {
            EntityIcon(appearance: folder.appearance, fallbackSymbol: "folder.fill", size: 26)
                .frame(width: iconSize, height: iconSize)
                .background(tint.opacity(0.18), in: .rect(cornerRadius: ListCard.thumbnailRadius))

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.caption(for: folder))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    // No badge for being a folder: the coloured well beside
                    // this line has already said so. Only the states the
                    // well cannot show get a mark of their own.
                    if folder.isLocked {
                        ListRowBadge(symbolName: "lock.fill", tint: tint)
                    }
                    if folder.isHidden {
                        ListRowBadge(symbolName: "eye.slash")
                    }

                    Spacer(minLength: 8)
                }
            }
        }
        .padding(ListCard.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ListCardBackground(isSelected: isSelected) }
        .contentShape(.rect(cornerRadius: ListCard.cornerRadius))
        .motionAware(NookMotion.interaction, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.name)")
        .accessibilityValue(Format.spokenCaption(for: folder))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
    /// How far the mat reaches past the picture.
    private let selectionInset: CGFloat = 8

    /// The mat is the wall's only highlight: it shows where the keyboard is
    /// resting as well as what is selected, the way the icon grid does.
    private var isHighlighted: Bool { isSelected || isCursor }

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
        // The glass draws its own edge and lift; a drop shadow on top of
        // it doubles up into a heavy halo.
        .glassEffect(.regular, in: .rect(cornerRadius: radius))
        // Behind the tile, so a selected picture is
        // shown exactly as an unselected one is.
        .background {
            RoundedRectangle(cornerRadius: radius + selectionInset)
                .fill(.secondary)
                .opacity(isHighlighted ? 0.35 : 0)
                .padding(-selectionInset)
        }
        .contentShape(.rect(cornerRadius: radius))
        .onHover { isHovering = $0 }
        .motionAware(.smooth(duration: 0.16), value: isHovering || isCursor)
        .motionAware(NookMotion.reflow, value: captionDisplay)
        .motionAware(.smooth(duration: 0.16), value: isHighlighted)
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
                .font(.callout.weight(.semibold))
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
        if showsTypeLabel || object.isHidden || object.isFavorite {
            HStack(spacing: 4) {
                if object.isHidden { GalleryBadge(symbolName: "eye.slash") }
                if object.isFavorite { GalleryBadge(symbolName: "star.fill") }
                if showsTypeLabel { GalleryBadge(symbolName: object.kind.symbolName) }
            }
            .padding(8)
        }
    }
}

/// A small circular glyph over a picture — used for state and type marks
/// (hidden, favorite, file type, locked) so every one of them reads the same
/// way, whether it sits over an object's thumbnail or a folder's icon.
struct GalleryBadge: View {
    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
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

    /// The mat is the wall's only highlight, so it marks the cursor too.
    private var isHighlighted: Bool { isSelected || isCursor }

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
        // The glass draws its own edge and lift; a drop shadow on top of
        // it doubles up into a heavy halo.
        .glassEffect(.regular, in: .rect(cornerRadius: radius))
        .background {
            RoundedRectangle(cornerRadius: radius + selectionInset)
                .fill(.secondary)
                .opacity(isHighlighted ? 0.35 : 0)
                .padding(-selectionInset)
        }
        .contentShape(.rect(cornerRadius: radius))
        .onHover { isHovering = $0 }
        .itemClick(select: select, open: onOpen)
        .motionAware(.smooth(duration: 0.16), value: isOpen)
        .motionAware(NookMotion.reflow, value: captionDisplay)
        .motionAware(.smooth(duration: 0.16), value: isHighlighted)
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
            // Same corner, same glyph treatment as a hidden, favorite or
            // typed object sitting beside it in the same wall of tiles.
            .overlay(alignment: .topTrailing) {
                if folder.isLocked {
                    GalleryBadge(symbolName: "lock.fill").padding(8)
                }
            }
    }
}

private struct FolderMasonryCaption: View {
    let folder: FolderSnapshot
    let color: ThumbnailColor

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(folder.name)
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
}

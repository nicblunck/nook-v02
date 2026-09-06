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
                Text(object.title)
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

            if object.isFavorite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary)
            }
            if object.isLocked {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.title)
        .accessibilityValue(Format.spokenCaption(for: object))
        // Selection is drawn as a tinted background, which is not something
        // VoiceOver can see.
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A folder row in the list view.
struct FolderListRow: View {
    let folder: FolderSnapshot

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
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.name)")
        .accessibilityValue(folderValue)
        .accessibilityAddTraits(.isButton)
    }

    private var folderValue: String {
        var parts = [Format.itemCount(folder.objectCount)]
        if folder.isLocked { parts.append("Locked") }
        return parts.joined(separator: ", ")
    }
}

/// A masonry tile: the picture, full-bleed, at its own proportions.
///
/// Nothing is written on it at rest — the wall is there to be read as pictures,
/// and a caption under every one turns it back into a list. The name arrives
/// under the pointer instead, on a material bar that stays legible over any
/// photograph in either appearance.
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
    /// Only the picture's resolution depends on this. The tile's width is the
    /// column's, which the layout has already sized.
    let scale: Double

    @State private var isHovering = false

    private var isCaptioned: Bool { isHovering || isCursor }

    private let radius: CGFloat = 14
    /// How far the mat reaches past the picture. Wider than the cursor ring's
    /// standoff, so the ring lands on the mat rather than beyond it.
    private let selectionInset: CGFloat = 8

    var body: some View {
        ZStack(alignment: .bottom) {
            ThumbnailView(object: object, maximumSize: min(1536, max(512, 420 * scale)))
                .aspectRatio(object.aspectRatio ?? 1, contentMode: .fit)
                .frame(maxWidth: .infinity)

            caption
                .opacity(isCaptioned ? 1 : 0)
        }
        .clipShape(.rect(cornerRadius: radius))
        .overlay(alignment: .topTrailing) { badge }
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
        .motionAware(.smooth(duration: 0.16), value: isCaptioned)
        .motionAware(.smooth(duration: 0.16), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.title)
        // The caption is only drawn where the pointer or the keyboard is, so
        // everything it says has to reach a reader who never sees it.
        .accessibilityValue(Format.spokenCaption(for: object))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(object.title)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(Format.caption(for: object))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var badge: some View {
        if object.isFavorite || object.isLocked {
            Image(systemName: object.isLocked ? "lock.fill" : "star.fill")
                .font(.caption2.weight(.semibold))
                .padding(5)
                .background(.regularMaterial, in: .circle)
                .padding(8)
        }
    }
}

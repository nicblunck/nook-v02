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

/// A masonry card: the thumbnail keeps the object's own proportions.
struct ObjectMasonryCard: View {
    let object: ObjectSnapshot
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailView(object: object)
                .aspectRatio(object.aspectRatio ?? 1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if object.isFavorite || object.isLocked {
                        Image(systemName: object.isLocked ? "lock.fill" : "star.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.45), in: .circle)
                            .padding(6)
                    }
                }

            Text(object.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear))
        }
        .contentShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.title)
        .accessibilityValue(Format.spokenCaption(for: object))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

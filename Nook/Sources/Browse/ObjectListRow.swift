import SwiftUI
import NookLibrary

/// A dense row for the list view: enough metadata to scan a large mixed
/// library without opening anything.
struct ObjectListRow: View {
    let object: ObjectSnapshot
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(object: object, maximumSize: 128)
                .frame(width: 38, height: 38)
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
                .frame(width: 74, alignment: .leading)

            Text(Format.bytes(object.byteSize) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)

            Text(object.dateAdded.formatted(date: .numeric, time: .omitted))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
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
        .accessibilityValue(Format.caption(for: object))
    }
}

/// A folder row in the list view.
struct FolderListRow: View {
    let folder: FolderSnapshot

    var body: some View {
        HStack(spacing: 12) {
            EntityIcon(appearance: folder.appearance, fallbackSymbol: "folder.fill", size: 20)
                .frame(width: 38, height: 38)

            Text(folder.name).lineLimit(1)
            Spacer(minLength: 8)
            Text(folder.objectCount == 1 ? "1 item" : "\(folder.objectCount) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(folder.name)")
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
    }
}

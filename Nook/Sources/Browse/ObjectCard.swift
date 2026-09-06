import SwiftUI
import NookLibrary

/// A card in the grid: preview first, with restrained secondary information.
struct ObjectCard: View {
    let object: ObjectSnapshot
    let isSelected: Bool

    @ScaledMetric(relativeTo: .body) private var previewHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailView(object: object)
                .frame(height: previewHeight)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topTrailing) { badges }
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(object.title)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(Format.caption(for: object))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 1.5 : 0)
        }
        .contentShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.title)
        // The badges below are drawn without labels, so the spoken caption is
        // what carries locked and favourite to a reader who cannot see them.
        .accessibilityValue(Format.spokenCaption(for: object))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Privacy and state indicators sit on the card without revealing anything
    /// the object is protecting.
    private var badges: some View {
        HStack(spacing: 4) {
            if object.isLocked { badge("lock.fill") }
            if object.isFavorite { badge("star.fill") }
        }
        .padding(6)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.45), in: .circle)
    }
}

/// A folder as it appears inline in the canvas.
struct FolderCard: View {
    let folder: FolderSnapshot
    let onOpen: () -> Void

    @ScaledMetric(relativeTo: .body) private var previewHeight: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill((Color(hex: folder.appearance.colorHex) ?? .accentColor).opacity(0.14))
                EntityIcon(appearance: folder.appearance, fallbackSymbol: "folder.fill", size: 34)
            }
            .frame(height: previewHeight)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.callout).lineLimit(1)
                Text(itemCountDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .contentShape(.rect(cornerRadius: 12))
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
}

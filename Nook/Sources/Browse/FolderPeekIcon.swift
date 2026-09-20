import SwiftUI
import NookLibrary

/// The original Nook folder drawing, fed by privacy-filtered v02 snapshots.
struct FolderPeekIcon: View {
    let folder: FolderSnapshot
    let objects: [ObjectSnapshot]
    let isOpen: Bool
    let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var peeks: [ObjectSnapshot] {
        folder.visibility == .full ? Array(objects.prefix(3).reversed()) : []
    }

    var body: some View {
        let contents = peeks
        let subfolders = folder.visibility == .full ? min(3 - contents.count, folder.subfolderCount) : 0
        FolderScene(
            width: width,
            tint: Color(hex: folder.appearance.colorHex) ?? .accentColor,
            openness: isOpen && !reduceMotion ? 1 : 0,
            sheetCount: contents.count + subfolders
        ) { index, size in
            if index < subfolders {
                ZStack {
                    Color.white
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                }
            } else {
                let object = contents[index - subfolders]
                ThumbnailView(object: object, maximumSize: 160)
                    // Recreate thumbnail state when privacy or content changes.
                    .id(object)
                    .background(.background)
            }
        } stamp: { height in
            if let emoji = folder.appearance.emoji {
                Text(emoji).font(.system(size: height * 0.26))
            } else if let symbol = folder.appearance.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: height * 0.24, weight: .medium))
                    .foregroundStyle(.black.opacity(0.2))
                    .shadow(color: .white.opacity(0.45), radius: 0, y: 1)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: -0.5)
            }
        }
        // Opening is the layout's own timing rather than a spring of its
        // own. The old one overshot, and `openness` past 1 does not stop at
        // the open folder — it keeps extrapolating the spread, throwing a
        // sheet out past the icon square and over the name underneath.
        .nookMotion(.presentation, value: isOpen && !reduceMotion)
        .accessibilityHidden(true)
    }
}

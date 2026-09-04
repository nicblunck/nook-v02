import SwiftUI
import NookLibrary

/// Renders an object's thumbnail, falling back to a type glyph while it loads
/// or when there is nothing to render.
///
/// A locked object arrives here with no blob and therefore no thumbnail, so a
/// protected preview cannot be drawn even by mistake.
struct ThumbnailView: View {
    let object: ObjectSnapshot
    var maximumSize: CGFloat = 512

    @Environment(\.thumbnailLoader) private var loader
    @State private var image: Image?
    @State private var didAttempt = false

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: object.id) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            Image(systemName: object.isLocked ? "lock.fill" : object.kind.symbolName)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .opacity(didAttempt ? 1 : 0.55)
        }
    }

    private func load() async {
        image = nil
        didAttempt = false
        guard let data = await loader?.thumbnail(for: object, maximumSize: maximumSize) else {
            didAttempt = true
            return
        }
        image = Image(platformData: data)
        didAttempt = true
    }
}

extension EnvironmentValues {
    @Entry var thumbnailLoader: ThumbnailStore?
}

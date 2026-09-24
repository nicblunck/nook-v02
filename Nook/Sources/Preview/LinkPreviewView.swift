import SwiftUI
import NookLibrary

/// A link has no stored file to hand Quick Look, and Nook has no browser of
/// its own — the page belongs to Safari or the default browser. So stepping
/// onto a link shows what importing it captured (thumbnail, title, domain)
/// and an Open button that goes wherever links go.
struct LinkPreviewView: View {
    let model: LibraryModel
    let object: ObjectSnapshot

    @Environment(\.thumbnailLoader) private var loader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnail: Image?
    @State private var didLoad = false

    /// Link thumbnails are nearly always a page's share image, which is
    /// drawn at this shape. The space is held at it before the picture
    /// arrives, so nothing below it moves when it does.
    private static let shareImageAspectRatio = 1.91

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            // The picture is drawn at its own shape inside the held space and
            // only its own corners are rounded — no placeholder box behind it
            // to show at a different size.
            Color.clear
                .aspectRatio(object.aspectRatio ?? Self.shareImageAspectRatio, contentMode: .fit)
                .frame(maxWidth: 560)
                .overlay {
                    if let thumbnail {
                        thumbnail
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .transition(.opacity)
                    } else if didLoad {
                        Image(systemName: object.kind.symbolName)
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? NookMotion.reduced : NookMotion.interaction, value: didLoad)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(object.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let domain = object.sourceDomain {
                    Text(domain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let url = object.sourceURL {
                Button {
                    model.openLink(url)
                } label: {
                    Label("Open", systemImage: "safari")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    private func load() async {
        if let data = await loader?.thumbnail(for: object) {
            thumbnail = Image(platformData: data)
        }
        didLoad = true
    }
}

import SwiftUI
import NookLibrary
#if os(macOS)
import AVFoundation
#endif

/// Renders an object's thumbnail, falling back to a type glyph while it loads
/// or when there is nothing to render.
///
/// An object buried in a locked folder is excluded outright rather than
/// arriving here redacted, so there is no protected-preview case to guard
/// against — an object only ever reaches this view once it is fully
/// accessible.
struct ThumbnailView: View {
    let object: ObjectSnapshot
    var maximumSize: CGFloat = 512
    /// Masonry uses the rendered thumbnail as the final authority when stored
    /// metadata is absent or stale. Other thumbnail surfaces need no callback.
    var onAspectRatioChange: ((Double) -> Void)? = nil
    /// Masonry presentation borrows color and transparency from the thumbnail
    /// already being loaded here, avoiding a second fetch for the same card.
    var onAppearanceChange: ((ThumbnailAppearance?) -> Void)? = nil
    /// Holds the load back until the view is within about a screen of the
    /// scroll view's visible area. For a container that builds every card at
    /// once — the masonry wall — rather than lazily as they scroll in.
    var defersLoadingUntilNearScreen = false

    @Environment(\.thumbnailLoader) private var loader
    @Environment(\.originalLocator) private var originals
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    /// Whether the pointer has rested on a video long enough to play it.
    @State private var isPlayingHoverPreview = false
    @State private var hoverDelay: Task<Void, Never>?
    #endif
    /// The picture this view last loaded. Kept while a new size or a changed
    /// picture loads, so the card goes straight from one to the next.
    @State private var loaded: DecodedThumbnail?
    @State private var didAttempt = false
    @State private var isNearScreen = false
    @State private var cacheRevision = 0
    /// Whether the picture was waited on, and so has a glyph to give way from.
    @State private var wasWaitedOn = false

    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    var body: some View {
        if let hex = object.colorHex, let color = Color(hex: hex) {
            // A colour chip has nothing to load: the colour is the picture.
            color
                .onAppear {
                    onAspectRatioChange?(1)
                    onAppearanceChange?(ThumbnailAppearance(predominantColor: ThumbnailColor(hex: hex),
                                                            hasTransparentBackground: false))
                }
                .accessibilityHidden(true)
        } else {
            picture
                #if os(macOS)
                .overlay { hoverPreview }
                .onHover(perform: hoverChanged)
                #endif
        }
    }

    #if os(macOS)
    /// A video plays, silent and looping, under a resting pointer, the way
    /// the Finder's and Photos' do. Only once the original is on this Mac:
    /// a hover is no reason to download one.
    @ViewBuilder
    private var hoverPreview: some View {
        if isPlayingHoverPreview, let url = originals?.url(for: object) {
            HoverVideoPlayer(url: url)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        guard object.kind == .video else { return }
        hoverDelay?.cancel()
        guard hovering else {
            withAnimation(NookMotion.interaction) { isPlayingHoverPreview = false }
            return
        }
        // A pointer passing over on its way somewhere else starts nothing.
        hoverDelay = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            withAnimation(NookMotion.interaction) { isPlayingHoverPreview = true }
        }
    }
    #endif

    /// What to draw now. The store's memory is consulted while drawing, so a
    /// card scrolled back into view, or rebuilt by its container, shows its
    /// picture in its first frame rather than a glyph that blinks away.
    private var displayed: DecodedThumbnail? {
        guard object.isContentAccessible else { return nil }
        return loaded ?? loader?.cachedImage(for: object, maximumSize: maximumSize)
    }

    private var picture: some View {
        ZStack {
            if let displayed {
                Image(decorative: displayed.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(revealTransition)
            } else {
                placeholder
                    .transition(revealTransition)
            }
        }
        // Keyed on accessibility and on whether the original is here, not on
        // identity alone: locking or unlocking leaves the id unchanged, and so
        // does an original finishing its download. A task keyed on id alone
        // would give up once and never look again — which is why a thumbnail
        // saved on another device used to appear only after the tile happened
        // to be scrolled out of view and rebuilt.
        .task(id: TaskKey(
            id: object.id,
            isContentAccessible: object.isContentAccessible,
            blobAvailability: object.blobAvailability,
            cacheRevision: cacheRevision,
            isNearScreen: isNearScreen
        )) { await load() }
        .modifier(NearScreenTracker(
            isEnabled: defersLoadingUntilNearScreen,
            isNearScreen: $isNearScreen
        ))
        .onReceive(NotificationCenter.default.publisher(for: .nookThumbnailDidChange)) { notification in
            guard notification.object as? UUID == object.id.uuid else { return }
            loader?.evictCachedImages(for: object)
            cacheRevision += 1
        }
        // The picture is the object, and the surface showing it already
        // announces which object that is. Left visible to VoiceOver it would
        // add an unnamed image to every card.
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            Image(systemName: object.kind.symbolName)
                .font(.system(size: 22 * typeScale, weight: .regular))
                .foregroundStyle(.secondary)
                .opacity(didAttempt ? 1 : 0.55)
        }
        .motionAware(NookMotion.interaction, value: didAttempt)
    }

    /// The glyph gives way to the picture: it fades out, then the picture
    /// fades in over the space it left. A picture that was ready at once —
    /// cached, and asked for again as the gallery scrolls its tile back into
    /// view — is simply there.
    private var revealTransition: AnyTransition {
        wasWaitedOn ? .staged(reduceMotion: reduceMotion) : .identity
    }

    private struct TaskKey: Equatable {
        let id: ObjectID
        let isContentAccessible: Bool
        let blobAvailability: BlobAvailability?
        let cacheRevision: Int
        let isNearScreen: Bool
    }

    private func load() async {
        guard object.isContentAccessible, let loader else {
            loaded = nil
            onAppearanceChange?(nil)
            didAttempt = true
            return
        }

        // Already decoded: show it and stop, unless it is only the borrowed
        // picture, which is shown while this device tries for its own.
        if let cached = loader.cachedImage(for: object, maximumSize: maximumSize) {
            show(cached)
            if !cached.isBorrowed {
                didAttempt = true
                return
            }
        }

        guard !defersLoadingUntilNearScreen || isNearScreen else { return }

        let wasShowingPicture = displayed != nil
        if !wasShowingPicture { didAttempt = false }
        let requested = ContinuousClock.now
        guard let thumbnail = await loader.image(for: object, maximumSize: maximumSize),
              !Task.isCancelled
        else {
            if !Task.isCancelled {
                loaded = nil
                onAppearanceChange?(nil)
                didAttempt = true
            }
            return
        }
        if !wasShowingPicture {
            wasWaitedOn = ContinuousClock.now - requested > .milliseconds(60)
        }
        show(thumbnail)
        didAttempt = true
    }

    /// The aspect ratio and colours were worked out with the decode, off the
    /// main thread, so handing them on costs nothing here.
    private func show(_ thumbnail: DecodedThumbnail) {
        loaded = thumbnail
        onAspectRatioChange?(thumbnail.aspectRatio)
        onAppearanceChange?(ThumbnailAppearance(thumbnail.traits))
    }
}

/// Notices when a view comes within about a screen of its scroll view's
/// visible area, and remembers that it has. A view not inside a scroll view
/// counts as near at once.
private struct NearScreenTracker: ViewModifier {
    let isEnabled: Bool
    @Binding var isNearScreen: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.onGeometryChange(for: Bool.self) { proxy in
                guard let visible = proxy.bounds(of: .scrollView) else { return true }
                return visible
                    .insetBy(dx: -visible.width, dy: -visible.height)
                    .intersects(CGRect(origin: .zero, size: proxy.size))
            } action: { isNear in
                // Once loaded, a card stays loaded: scrolling away should not
                // cost a reload on the way back.
                if isNear { isNearScreen = true }
            }
        } else {
            content
        }
    }
}

/// A small, Sendable color value derived from a thumbnail. Keeping raw sRGB
/// components rather than `Color` makes it straightforward to compare, cache,
/// and test while SwiftUI colors remain a presentation detail.
struct ThumbnailColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let neutral = ThumbnailColor(red: 0.18, green: 0.18, blue: 0.2)

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init?(hex: String?) {
        guard let hex else { return nil }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    /// Black and white cross at a relative luminance of roughly 0.179. Picking
    /// the stronger side guarantees at least WCAG AA contrast for normal text.
    var contrastingTextColor: Color {
        usesDarkText ? .black : .white
    }

    var usesDarkText: Bool { relativeLuminance > 0.179 }

    private var relativeLuminance: Double {
        0.2126 * Self.linearized(red)
            + 0.7152 * Self.linearized(green)
            + 0.0722 * Self.linearized(blue)
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

/// Visual facts derived together from one small thumbnail rendering.
struct ThumbnailAppearance: Hashable, Sendable {
    let predominantColor: ThumbnailColor?
    let hasTransparentBackground: Bool

    init(predominantColor: ThumbnailColor?, hasTransparentBackground: Bool) {
        self.predominantColor = predominantColor
        self.hasTransparentBackground = hasTransparentBackground
    }

    /// The store samples every picture as it decodes it; this only gives
    /// those numbers a colour.
    init(_ traits: ThumbnailTraits) {
        self.init(
            predominantColor: traits.predominantColor.map {
                ThumbnailColor(red: $0.red, green: $0.green, blue: $0.blue)
            },
            hasTransparentBackground: traits.hasTransparentBackground
        )
    }
}

extension Notification.Name {
    static let nookThumbnailDidChange = Notification.Name("Nook.thumbnailDidChange")
}

extension EnvironmentValues {
    @Entry var thumbnailLoader: ThumbnailStore?
    @Entry var originalLocator: OriginalLocator?
}

/// Where an object's original file is on this device, for a view that needs
/// the bytes themselves rather than a thumbnail of them.
struct OriginalLocator {
    let model: LibraryModel

    func url(for object: ObjectSnapshot) -> URL? { model.localURL(for: object) }
}

#if os(macOS)
/// A muted, looping player filling its frame, for a video previewed in place.
private struct HoverVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {}

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func play(_ url: URL) {
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.play()
        }

        func stop() {
            player.pause()
            looper = nil
            player.removeAllItems()
        }
    }
}
#endif

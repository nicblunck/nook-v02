import SwiftUI
import NookLibrary

/// Opening a photo or video on the Mac grows it out of its tile in the
/// gallery, and closing it shrinks it back into the tile of whatever is
/// showing by then — the way Photos opens and closes one.
///
/// iOS has the system's zoom navigation transition for this; the Mac does
/// not. So each tile reports where it is drawn, and the picture is animated
/// between that frame and the one it fills in the viewer. The gallery stays
/// in place under the viewer, so the tile is there to leave from and to land
/// on.
///
/// Only the picture moves. The viewer appears and disappears at once
/// underneath it, and its background fades in and out with the flight, so
/// nothing else animates against it.
@MainActor
@Observable
final class MacPreviewZoom {
    /// Where the canvas and the viewer both measure frames from.
    static let coordinateSpace = "MacPreviewZoom"

    /// Where a tile draws its picture, and with what corners.
    struct Tile: Equatable {
        var frame: CGRect
        var cornerRadius: CGFloat
    }

    /// One trip of one picture between its tile and the viewer.
    struct Flight: Identifiable {
        let id: Int
        let object: ObjectSnapshot
        let picture: Image
        /// The tile it leaves from or lands on.
        let tile: Tile
        /// Whether it is on its way to the viewer, rather than back.
        let isOpening: Bool
    }

    private(set) var flight: Flight?
    /// Whether the picture in flight is at the viewer's end of its trip.
    private(set) var isAtViewer = false
    /// The viewer's background, fading in behind the picture as it opens and
    /// out as it closes.
    private(set) var backdropOpacity: Double = 0
    /// The viewer is held back until the picture opening it lands.
    private(set) var isOpening = false
    /// Pictures ready to fly, by object: the one open, and the one just opened
    /// from, so a close never waits on a load.
    private var pictures: [ObjectID: Image] = [:]

    /// Tiles laid out in the gallery right now. A tile scrolled out of
    /// reach is not there to zoom from or back into.
    @ObservationIgnored var tiles: [ObjectID: Tile] = [:]
    @ObservationIgnored var loader: ThumbnailStore?
    /// Which trip is current, so one cut short by the next does not finish on
    /// top of it.
    @ObservationIgnored private var generation = 0

    private let motion = Animation.smooth(duration: 0.32)

    /// Photos and videos, the things Photos zooms, from a tile on screen.
    func canZoom(_ object: ObjectSnapshot) -> Bool {
        switch object.kind {
        case .image, .screenshot, .video: tiles[object.id] != nil
        default: false
        }
    }

    /// Whether closing `object` now would zoom it back into its tile.
    func closes(_ object: ObjectSnapshot) -> Bool {
        canZoom(object) && pictures[object.id] != nil
    }

    func open(_ object: ObjectSnapshot) {
        guard canZoom(object) else { return }
        generation += 1
        let trip = generation
        flight = nil
        backdropOpacity = 0
        isOpening = true
        Task { @MainActor in
            guard let picture = await picture(for: object), trip == generation else {
                if trip == generation { isOpening = false }
                return
            }
            guard let tile = tiles[object.id] else {
                isOpening = false
                return
            }
            isAtViewer = false
            flight = Flight(id: trip, object: object, picture: picture, tile: tile, isOpening: true)
        }
    }

    func close(_ object: ObjectSnapshot) {
        generation += 1
        isOpening = false
        guard closes(object), let picture = pictures[object.id], let tile = tiles[object.id] else {
            flight = nil
            backdropOpacity = 0
            return
        }
        isAtViewer = true
        backdropOpacity = 1
        flight = Flight(id: generation, object: object, picture: picture, tile: tile, isOpening: false)
    }

    /// Readies the picture of whatever the viewer is showing, for when it
    /// closes.
    func prepare(_ object: ObjectSnapshot) {
        guard pictures[object.id] == nil else { return }
        Task { @MainActor in _ = await picture(for: object) }
    }

    /// Sets off a flight once its picture sits where the trip starts — called
    /// from the picture's own `onAppear`, so it never starts from nowhere.
    func takeOff(_ flight: Flight) {
        guard flight.id == generation else { return }
        withAnimation(motion) {
            isAtViewer = flight.isOpening
            backdropOpacity = flight.isOpening ? 1 : 0
        } completion: { [self] in
            guard flight.id == generation else { return }
            if flight.isOpening {
                // The viewer, now shown, has the same picture in the same
                // place; the one that flew fades off it in case the full-size
                // file is a moment behind.
                isOpening = false
                backdropOpacity = 0
                withAnimation(NookMotion.interaction) { self.flight = nil }
            } else {
                // Landed on its tile, which comes back as it goes.
                self.flight = nil
            }
        }
    }

    private func picture(for object: ObjectSnapshot) async -> Image? {
        if let picture = pictures[object.id] { return picture }
        guard let data = await loader?.thumbnail(for: object, maximumSize: 1024) else { return nil }
        let picture = Image(platformData: data)
        // A few are plenty: the one open and the few stepped through.
        if pictures.count > 8 { pictures.removeAll() }
        pictures[object.id] = picture
        return picture
    }
}

extension EnvironmentValues {
    @Entry var macPreviewZoom: MacPreviewZoom? = nil
}

/// The picture on its way, above the gallery and the viewer alike.
struct MacPreviewZoomOverlay: View {
    let zoom: MacPreviewZoom

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(.background)
                    .opacity(zoom.backdropOpacity)

                if let flight = zoom.flight {
                    let frame = zoom.isAtViewer ? fitted(flight.object, in: proxy.size) : flight.tile.frame
                    flight.picture
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(.rect(cornerRadius: zoom.isAtViewer ? 0 : flight.tile.cornerRadius))
                        .position(x: frame.midX, y: frame.midY)
                        .onAppear { zoom.takeOff(flight) }
                        .id(flight.id)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The space the photo or video fills in the viewer: fitted whole and
    /// centred, as the viewer draws it.
    private func fitted(_ object: ObjectSnapshot, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let aspect = CGFloat(object.aspectRatio ?? 1)
        let fitted = size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}

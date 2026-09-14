import SwiftUI
import ImageIO
import NookLibrary

/// Renders an object's thumbnail, falling back to a type glyph while it loads
/// or when there is nothing to render.
///
/// A locked object arrives here with no blob and therefore no thumbnail, so a
/// protected preview cannot be drawn even by mistake.
struct ThumbnailView: View {
    let object: ObjectSnapshot
    var maximumSize: CGFloat = 512
    /// Masonry uses the rendered thumbnail as the final authority when stored
    /// metadata is absent or stale. Other thumbnail surfaces need no callback.
    var onAspectRatioChange: ((Double) -> Void)? = nil
    /// Masonry presentation borrows color and transparency from the thumbnail
    /// already being loaded here, avoiding a second fetch for the same card.
    var onAppearanceChange: ((ThumbnailAppearance?) -> Void)? = nil

    @Environment(\.thumbnailLoader) private var loader
    @State private var image: Image?
    @State private var didAttempt = false
    @State private var cacheRevision = 0

    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

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
        // Keyed on accessibility as well as identity: locking or unlocking
        // leaves the id unchanged, and a task keyed on id alone would never
        // rerun to drop or refetch the picture.
        .task(id: TaskKey(
            id: object.id,
            isContentAccessible: object.isContentAccessible,
            cacheRevision: cacheRevision
        )) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .nookThumbnailDidChange)) { notification in
            guard notification.object as? UUID == object.id.uuid else { return }
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
            Image(systemName: object.isLocked ? "lock.fill" : object.kind.symbolName)
                .font(.system(size: 22 * typeScale, weight: .regular))
                .foregroundStyle(.secondary)
                .opacity(didAttempt ? 1 : 0.55)
        }
    }

    private struct TaskKey: Equatable {
        let id: ObjectID
        let isContentAccessible: Bool
        let cacheRevision: Int
    }

    private func load() async {
        image = nil
        didAttempt = false
        guard let data = await loader?.thumbnail(for: object, maximumSize: maximumSize) else {
            onAppearanceChange?(nil)
            didAttempt = true
            return
        }
        image = Image(platformData: data)
        if let onAspectRatioChange,
           let aspectRatio = displayAspectRatio(in: data) {
            onAspectRatioChange(aspectRatio)
        }
        if onAppearanceChange != nil {
            onAppearanceChange?(ThumbnailAppearance.analyze(data))
        }
        didAttempt = true
    }

    private func displayAspectRatio(in data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        let ratio = orientation.map { (5...8).contains($0) } == true
            ? height / width
            : width / height
        return ratio.isFinite ? ratio : nil
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

    /// Finds the most frequent quantized color family in a small rendering of
    /// the thumbnail and notes whether a meaningful portion remains transparent.
    /// The original pixels in the winning family are averaged, producing a
    /// stable color without expensive clustering work for every visible item.
    static func analyze(_ data: Data) -> ThumbnailAppearance? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let side = 32
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return nil }

        struct Bucket {
            var weight = 0
            var red = 0
            var green = 0
            var blue = 0
        }

        var buckets: [Int: Bucket] = [:]
        var transparentPixelCount = 0
        let pixelCount = pixels.count / bytesPerPixel
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let alpha = Int(pixels[offset + 3])
            if alpha < 250 { transparentPixelCount += 1 }
            guard alpha >= 64 else { continue }
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            let key = ((red >> 4) << 8) | ((green >> 4) << 4) | (blue >> 4)
            var bucket = buckets[key, default: Bucket()]
            bucket.weight += alpha
            bucket.red += red * alpha
            bucket.green += green * alpha
            bucket.blue += blue * alpha
            buckets[key] = bucket
        }

        let predominant = buckets.max(by: { first, second in
            if first.value.weight == second.value.weight {
                return first.key > second.key
            }
            return first.value.weight < second.value.weight
        })?.value

        let predominantColor: ThumbnailColor?
        if let predominant, predominant.weight > 0 {
            predominantColor = ThumbnailColor(
                red: Double(predominant.red) / Double(predominant.weight) / 255,
                green: Double(predominant.green) / Double(predominant.weight) / 255,
                blue: Double(predominant.blue) / Double(predominant.weight) / 255
            )
        } else {
            predominantColor = nil
        }

        return ThumbnailAppearance(
            predominantColor: predominantColor,
            // Ignore isolated antialiasing artifacts while still recognizing
            // transparent canvases and cut-out artwork.
            hasTransparentBackground: transparentPixelCount * 50 >= pixelCount
        )
    }
}

extension Notification.Name {
    static let nookThumbnailDidChange = Notification.Name("Nook.thumbnailDidChange")
}

extension EnvironmentValues {
    @Entry var thumbnailLoader: ThumbnailStore?
}

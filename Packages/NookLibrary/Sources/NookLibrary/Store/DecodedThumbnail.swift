import Foundation
import CoreGraphics
import ImageIO

/// A thumbnail decoded and ready to draw, with the facts every surface asks
/// of it worked out once alongside.
///
/// Decoding, measuring and sampling a picture are each cheap on their own and
/// expensive when a whole wall of cards does them on the main thread at once.
/// Doing all three together, off the main thread, and keeping the result means
/// a card scrolled back into view has nothing left to compute.
public struct DecodedThumbnail: Sendable {
    /// Already upright: any orientation the file recorded has been applied.
    public let image: CGImage
    /// Width over height of the picture as it is displayed.
    public let aspectRatio: Double
    public let traits: ThumbnailTraits
    /// Whether this is the small rendering that travelled from another
    /// device, standing in until this one can render its own.
    public let isBorrowed: Bool

    /// What the picture costs to keep in memory, for the cache's budget.
    var cost: Int { image.bytesPerRow * image.height }

    /// Decodes image bytes at no more than `maximumPixelSize` on their longest
    /// edge. Returns nil when the bytes are not a picture ImageIO can read.
    static func decode(_ data: Data, maximumPixelSize: Int, isBorrowed: Bool = false) -> DecodedThumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            // Decoded here, on the caller's thread, rather than lazily the
            // first time the picture is drawn — which would be on the main one.
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0
        else { return nil }
        return DecodedThumbnail(
            image: image,
            aspectRatio: Double(image.width) / Double(image.height),
            traits: ThumbnailTraits.analyze(image),
            isBorrowed: isBorrowed
        )
    }
}

/// Visual facts sampled from a thumbnail, as plain data. The app turns them
/// into colours; keeping them free of any UI framework lets the store work
/// them out off the main thread and cache them with the picture.
public struct ThumbnailTraits: Hashable, Sendable {
    /// The most frequent colour family in the picture, as sRGB components
    /// from 0 to 1, or nil when the picture is entirely transparent.
    public let predominantColor: Components?
    /// Whether a meaningful portion of the picture is see-through: cut-out
    /// artwork, logos, a transparent canvas.
    public let hasTransparentBackground: Bool

    public struct Components: Hashable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
    }

    public init(predominantColor: Components?, hasTransparentBackground: Bool) {
        self.predominantColor = predominantColor
        self.hasTransparentBackground = hasTransparentBackground
    }

    /// Finds the most frequent quantized colour family in a small rendering of
    /// the picture and notes whether a meaningful portion remains transparent.
    /// The original pixels in the winning family are averaged, producing a
    /// stable colour without expensive clustering work for every visible item.
    static func analyze(_ image: CGImage) -> ThumbnailTraits {
        guard let pixels = samplePixels(of: image) else {
            return ThumbnailTraits(predominantColor: nil, hasTransparentBackground: false)
        }

        struct Bucket {
            var weight = 0
            var red = 0
            var green = 0
            var blue = 0
        }

        var buckets: [Int: Bucket] = [:]
        var transparentPixelCount = 0
        let pixelCount = pixels.count / 4
        for offset in stride(from: 0, to: pixels.count, by: 4) {
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

        let predominantColor: Components?
        if let predominant, predominant.weight > 0 {
            predominantColor = Components(
                red: Double(predominant.red) / Double(predominant.weight) / 255,
                green: Double(predominant.green) / Double(predominant.weight) / 255,
                blue: Double(predominant.blue) / Double(predominant.weight) / 255
            )
        } else {
            predominantColor = nil
        }

        return ThumbnailTraits(
            predominantColor: predominantColor,
            hasTransparentBackground: !isMostlyOpaque(transparentPixelCount, of: pixelCount)
        )
    }

    /// Whether a picture genuinely uses transparency. The same test the
    /// appearance analysis uses, so a picture saved as PNG for its alpha is
    /// also the one the masonry grid mounts as a cut-out.
    static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }
        guard let pixels = samplePixels(of: image) else { return false }
        let transparent = stride(from: 3, to: pixels.count, by: 4)
            .reduce(into: 0) { count, offset in
                if pixels[offset] < 250 { count += 1 }
            }
        return !isMostlyOpaque(transparent, of: pixels.count / 4)
    }

    /// The 2% floor ignores the antialiased edges almost every rendering has
    /// while still recognising a transparent canvas.
    private static func isMostlyOpaque(_ transparentCount: Int, of pixelCount: Int) -> Bool {
        transparentCount * 50 < pixelCount
    }

    /// Draws the picture into a 32-pixel square of premultiplied RGBA, which
    /// is all either question needs.
    private static func samplePixels(of image: CGImage) -> [UInt8]? {
        let side = 32
        let bytesPerRow = side * 4
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
        return rendered ? pixels : nil
    }
}

/// Decoded thumbnails kept in memory, readable from any thread.
///
/// `NSCache` is thread-safe and gives memory back under pressure on its own,
/// but is not marked `Sendable`; this wrapper is the one place that vouches
/// for it.
final class ThumbnailMemoryCache: @unchecked Sendable {
    private final class Entry {
        let thumbnail: DecodedThumbnail
        init(_ thumbnail: DecodedThumbnail) { self.thumbnail = thumbnail }
    }

    private let cache = NSCache<NSString, Entry>()

    init(totalCostLimit: Int) {
        cache.totalCostLimit = totalCostLimit
    }

    subscript(key: String) -> DecodedThumbnail? {
        get { cache.object(forKey: key as NSString)?.thumbnail }
        set {
            if let newValue {
                cache.setObject(Entry(newValue), forKey: key as NSString, cost: newValue.cost)
            } else {
                cache.removeObject(forKey: key as NSString)
            }
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

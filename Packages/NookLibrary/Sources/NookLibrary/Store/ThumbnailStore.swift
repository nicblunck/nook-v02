import Foundation
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Generates and caches preview thumbnails.
///
/// Thumbnails are derived content: disposable and rebuildable. They are cached
/// under `Derived/`, keyed by content hash so two objects sharing one blob also
/// share one rendered thumbnail.
///
/// A device that holds the original renders its own, full-quality picture. A
/// device that does not — the Mac, moments after something was saved on the
/// phone — would otherwise have to download the whole original to draw one
/// tile, so it borrows the small rendering that travelled with the metadata
/// instead, and upgrades to its own once the bytes arrive.
public actor ThumbnailStore {
    /// Supplies the small rendering that syncs with an object's metadata.
    /// Injected rather than reached for, so this store keeps knowing nothing
    /// about persistence.
    public typealias SyncedThumbnailProvider = @Sendable (ObjectID) async -> Data?

    /// The longest edge of a rendering meant to travel between devices, and
    /// the ceiling on its encoded size. Both are chosen to stay far below
    /// CloudKit's per-record limit: metadata that arrives late helps nobody.
    public static let syncedMaximumSize: CGFloat = 400
    public static let syncedMaximumByteCount = 512 * 1024

    /// Identifies what produced a synced rendering, so a change here can be
    /// found and regenerated rather than silently leaving stale pictures.
    public static let syncedGeneratorIdentifier = "quicklook-sync-1"

    private let directory: URL
    private let fileManager = FileManager.default
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var syncedThumbnailProvider: SyncedThumbnailProvider?

    public init(directory: URL) throws {
        self.directory = directory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Returns image data for an object's thumbnail, generating it on first
    /// ask. Returns nil when the object has no renderable content, or when its
    /// content is protected — an object still buried in a locked folder
    /// arrives here with no blob.
    public func thumbnail(for object: ObjectSnapshot, maximumSize: CGFloat = 512) async -> Data? {
        guard object.isContentAccessible else { return nil }

        // A link has no stored payload, so its preview picture is cached
        // against the object itself rather than against a blob.
        guard let blob = object.blob else {
            return cachedData(forKey: previewKey(for: object.id))
        }

        let key = "\(blob.hash.hexValue)-\(Int(maximumSize))"

        if let cached = cachedData(forKey: key) { return cached }

        // Nothing to wait for when the bytes are not here: show the picture
        // that came with the metadata rather than an hourglass over a download
        // the size of the original.
        if !isOriginalPresent(blob),
           let synced = await syncedThumbnail(for: object.id, hash: blob.hash) {
            return synced
        }

        if let existing = inFlight[key] { return await existing.value }

        let task = Task<Data?, Never> { [directory] in
            guard let source = await sourceURL(for: blob) else { return nil }
            guard let data = await Self.render(source: source, maximumSize: maximumSize) else { return nil }
            try? data.write(to: directory.appending(path: "\(key).png"), options: .atomic)
            return data
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        guard let result else {
            // The original never arrived, or Quick Look found nothing in it.
            // A borrowed picture still beats a glyph.
            return await syncedThumbnail(for: object.id, hash: blob.hash)
        }

        // This device now has a better rendering of its own.
        discardSyncedThumbnail(for: blob.hash)
        return result
    }

    /// Renders the small copy meant to travel with an object's metadata.
    /// Returns nil when there is nothing renderable, which the caller records
    /// so no device tries again.
    public func renderSyncedThumbnail(from source: URL) async -> Data? {
        await Self.renderSynced(source: source)
    }

    public func attach(syncedThumbnailProvider: @escaping SyncedThumbnailProvider) {
        self.syncedThumbnailProvider = syncedThumbnailProvider
    }

    /// Caches a downloaded link preview picture for an object.
    public func storePreviewImage(_ data: Data, for id: ObjectID) {
        try? data.write(to: directory.appending(path: "\(previewKey(for: id)).png"), options: .atomic)
    }

    public func hasPreviewImage(for id: ObjectID) -> Bool {
        cachedData(forKey: previewKey(for: id)) != nil
    }

    /// The displayed dimensions of a cached link preview. Older link records
    /// predate persisted dimensions, so this lets the app repair their
    /// masonry proportions without downloading the same image again.
    public func cachedPreviewImageDimensions(for id: ObjectID) -> (width: Int, height: Int)? {
        guard let data = cachedData(forKey: previewKey(for: id)),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        return MediaMetadataReader.orientedPixelDimensions(
            width: width,
            height: height,
            orientation: orientation
        )
    }

    private func previewKey(for id: ObjectID) -> String {
        "link-\(id.uuid.uuidString)"
    }

    /// Cached apart from rendered thumbnails: a borrowed picture is smaller
    /// than one this device would make, and must not satisfy a later request
    /// for the real thing.
    private func syncedKey(for hash: ContentHash) -> String {
        "synced-\(hash.hexValue)"
    }

    /// Fetches the travelling rendering once, then serves it from disk. Keyed
    /// by content hash on the way out so two objects sharing a blob share the
    /// borrowed picture too, exactly as they share a rendered one.
    private func syncedThumbnail(for id: ObjectID, hash: ContentHash) async -> Data? {
        let key = syncedKey(for: hash)
        if let cached = cachedData(forKey: key, extension: syncedFileExtension) { return cached }
        guard let provider = syncedThumbnailProvider,
              let data = await provider(id),
              !data.isEmpty
        else { return nil }
        try? data.write(
            to: fileURL(forKey: key, extension: syncedFileExtension),
            options: .atomic
        )
        return data
    }

    private func discardSyncedThumbnail(for hash: ContentHash) {
        try? fileManager.removeItem(
            at: fileURL(forKey: syncedKey(for: hash), extension: syncedFileExtension)
        )
    }

    /// Synced payloads are PNG or JPEG depending on the picture, so the cache
    /// file does not claim a format it may not hold.
    private let syncedFileExtension = "thumb"

    private func isOriginalPresent(_ blob: BlobDescriptor) -> Bool {
        blobStore?.isAvailableLocally(blob) ?? false
    }

    /// Discards every cached thumbnail. Safe at any time: they regenerate.
    public func clear() throws {
        try fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Internals

    private var blobStore: (any BlobStore)?

    public func attach(blobStore: any BlobStore) {
        self.blobStore = blobStore
    }

    private func sourceURL(for descriptor: BlobDescriptor) async -> URL? {
        try? await blobStore?.materialize(descriptor)
    }

    private func fileURL(forKey key: String, extension ext: String = "png") -> URL {
        directory.appending(path: "\(key).\(ext)")
    }

    private func cachedData(forKey key: String, extension ext: String = "png") -> Data? {
        let url = fileURL(forKey: key, extension: ext)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// One generator for every type. Quick Look already knows how to render
    /// images, PDFs, video frames and most documents, so the app does not need
    /// a renderer per media type.
    private static func render(source: URL, maximumSize: CGFloat) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: source,
            size: CGSize(width: maximumSize, height: maximumSize),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return pngData(from: representation.cgImage)
    }

    /// Renders the copy that travels between devices. Smaller than a local
    /// rendering, and encoded for size rather than fidelity, because it is
    /// standing in only until the original arrives.
    private static func renderSynced(source: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: source,
            size: CGSize(width: syncedMaximumSize, height: syncedMaximumSize),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return encodedForSync(representation.cgImage)
    }

    /// JPEG unless the picture genuinely uses transparency — cut-out artwork
    /// and logos read as damage on the black an alpha-less encoder leaves
    /// behind, and the masonry grid reads transparency from these bytes to
    /// decide how to mount a card.
    private static func encodedForSync(_ image: CGImage) -> Data? {
        if hasTransparency(image),
           let png = pngData(from: image),
           png.count <= syncedMaximumByteCount {
            return png
        }
        for quality in [0.7, 0.5, 0.35] {
            guard let jpeg = jpegData(from: image, quality: quality) else { continue }
            if jpeg.count <= syncedMaximumByteCount { return jpeg }
        }
        return nil
    }

    /// Samples the picture small and counts pixels that are not fully opaque.
    /// The 2% floor ignores the antialiased edges almost every rendering has
    /// while still recognising a transparent canvas.
    private static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }

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
        guard rendered else { return false }

        let transparent = stride(from: 3, to: pixels.count, by: 4)
            .reduce(into: 0) { count, offset in
                if pixels[offset] < 250 { count += 1 }
            }
        return transparent * 50 >= side * side
    }

    private static func pngData(from image: CGImage) -> Data? {
        encoded(image, as: UTType.png, properties: nil)
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        encoded(image, as: UTType.jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: quality as NSNumber
        ])
    }

    private static func encoded(
        _ image: CGImage,
        as type: UTType,
        properties: [CFString: Any]?
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

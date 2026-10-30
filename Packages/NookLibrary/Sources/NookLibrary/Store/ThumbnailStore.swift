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

    /// The sizes thumbnails are rendered at. A request is rounded up to the
    /// nearest of them, so dragging a size slider through every value it has
    /// reuses three renderings rather than making one per step.
    public static let renderSizes = [256, 512, 1024]

    /// The rendering size that serves a request: the smallest that is at least
    /// as large, and the largest for anything beyond it.
    public static func renderSize(for maximumSize: CGFloat) -> Int {
        renderSizes.first { CGFloat($0) >= maximumSize } ?? renderSizes[renderSizes.count - 1]
    }

    /// Names a rendering on disk and in memory. The version prefix leaves
    /// renderings made under the old per-pixel scheme unread, to be swept up
    /// once rather than mistaken for these.
    static func renderedKey(for hash: ContentHash, size: Int) -> String {
        "v2-\(hash.hexValue)-\(size)"
    }

    /// Room for a few screens of large pictures. `NSCache` gives memory back
    /// under pressure on its own, so this is a ceiling, not a reservation.
    #if os(macOS)
    private static let memoryCostLimit = 256 * 1024 * 1024
    #else
    private static let memoryCostLimit = 128 * 1024 * 1024
    #endif

    private nonisolated let directory: URL
    /// Decoded pictures, readable without waiting on this actor, so a card
    /// scrolled back into view can draw its picture in the same frame.
    private nonisolated let memory = ThumbnailMemoryCache(totalCostLimit: ThumbnailStore.memoryCostLimit)
    private let fileManager = FileManager.default
    /// The only reason this is an actor: two cards asking for the same picture
    /// at once share one Quick Look rendering. Reading and decoding what is
    /// already on disk happens outside it, so cards do not queue behind one
    /// another to do work that does not conflict.
    private var inFlight: [String: Task<Rendering?, Never>] = [:]
    private var syncedThumbnailProvider: SyncedThumbnailProvider?

    public init(directory: URL) throws {
        self.directory = directory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        Task.detached(priority: .background) {
            Self.removeLegacyRenderings(in: directory)
        }
    }

    // MARK: Pictures

    /// Returns an object's thumbnail if it is already decoded in memory,
    /// without waiting. A view asks this while it is drawn, so a picture it has
    /// shown before is there at once instead of after a placeholder.
    ///
    /// The answer may be a borrowed picture — check `isBorrowed` and keep
    /// loading — or a larger rendering than was asked for, which draws just as
    /// well.
    public nonisolated func cachedImage(for object: ObjectSnapshot, maximumSize: CGFloat = 512) -> DecodedThumbnail? {
        guard object.isContentAccessible else { return nil }
        let size = Self.renderSize(for: maximumSize)
        if let cached = cachedRendering(for: object, atLeast: size) { return cached }
        guard let blob = object.blob else { return nil }
        return memory[syncedKey(for: blob.hash)]
    }

    /// Returns an object's thumbnail, decoded and analysed off the main thread,
    /// generating it on first ask. Returns nil when the object has no
    /// renderable content, or when its content is protected — an object still
    /// buried in a locked folder arrives here with no blob.
    @concurrent
    public nonisolated func image(for object: ObjectSnapshot, maximumSize: CGFloat = 512) async -> DecodedThumbnail? {
        guard object.isContentAccessible else { return nil }
        let size = Self.renderSize(for: maximumSize)
        if let cached = cachedRendering(for: object, atLeast: size) { return cached }

        // A link has no stored payload, so its preview picture is cached
        // against the object itself rather than against a blob.
        guard let blob = object.blob else {
            guard let data = Self.read(fileURL(forKey: previewKey(for: object.id))),
                  let decoded = DecodedThumbnail.decode(data, maximumPixelSize: size)
            else { return nil }
            memory[linkMemoryKey(for: object.id, size: size)] = decoded
            return decoded
        }

        let key = Self.renderedKey(for: blob.hash, size: size)
        if let data = Self.read(fileURL(forKey: key, extension: renderedFileExtension)),
           let decoded = DecodedThumbnail.decode(data, maximumPixelSize: size) {
            memory[key] = decoded
            return decoded
        }

        switch await resolve(object: object, blob: blob, key: key, size: size) {
        case .rendered(let rendering):
            memory[key] = rendering.thumbnail
            return rendering.thumbnail
        case .borrowed(let data):
            guard let decoded = DecodedThumbnail.decode(data, maximumPixelSize: size, isBorrowed: true) else {
                return nil
            }
            memory[syncedKey(for: blob.hash)] = decoded
            return decoded
        case nil:
            return nil
        }
    }

    /// Returns the encoded bytes of an object's thumbnail, generating it on
    /// first ask, for a caller that wants the file rather than a picture to
    /// draw. Follows exactly the same rules as `image(for:maximumSize:)`.
    public func thumbnail(for object: ObjectSnapshot, maximumSize: CGFloat = 512) async -> Data? {
        guard object.isContentAccessible else { return nil }
        guard let blob = object.blob else {
            return Self.read(fileURL(forKey: previewKey(for: object.id)))
        }
        let size = Self.renderSize(for: maximumSize)
        let key = Self.renderedKey(for: blob.hash, size: size)
        if let cached = Self.read(fileURL(forKey: key, extension: renderedFileExtension)) { return cached }
        switch await resolve(object: object, blob: blob, key: key, size: size) {
        case .rendered(let rendering): return rendering.data
        case .borrowed(let data): return data
        case nil: return nil
        }
    }

    /// Forgets the decoded pictures of one object, for when its picture has
    /// changed underneath them. The files on disk are left for the next ask.
    public nonisolated func evictCachedImages(for object: ObjectSnapshot) {
        for size in Self.renderSizes {
            memory[linkMemoryKey(for: object.id, size: size)] = nil
            if let blob = object.blob {
                memory[Self.renderedKey(for: blob.hash, size: size)] = nil
            }
        }
        if let blob = object.blob {
            memory[syncedKey(for: blob.hash)] = nil
        }
    }

    /// A picture this device rendered, with the bytes it saved for it.
    struct Rendering: Sendable {
        let thumbnail: DecodedThumbnail
        let data: Data
    }

    private enum Resolution: Sendable {
        case rendered(Rendering)
        /// The small rendering that travelled with the metadata, still encoded.
        case borrowed(Data)
    }

    /// Everything past the disk cache: the borrowed picture when the original
    /// is not here, otherwise a single shared rendering of it.
    private func resolve(object: ObjectSnapshot, blob: BlobDescriptor, key: String, size: Int) async -> Resolution? {
        // Nothing to wait for when the bytes are not here: show the picture
        // that came with the metadata rather than an hourglass over a download
        // the size of the original.
        if !isOriginalPresent(blob),
           let synced = await syncedThumbnail(for: object.id, hash: blob.hash) {
            return .borrowed(synced)
        }

        if let existing = inFlight[key] {
            return await existing.value.map(Resolution.rendered)
        }

        let destination = fileURL(forKey: key, extension: renderedFileExtension)
        let task = Task<Rendering?, Never> {
            guard let source = await sourceURL(for: blob) else { return nil }
            return await Self.renderAndSave(source: source, size: size, to: destination)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        guard let result else {
            // The original never arrived, or Quick Look found nothing in it.
            // A borrowed picture still beats a glyph.
            return await syncedThumbnail(for: object.id, hash: blob.hash).map(Resolution.borrowed)
        }

        // This device now has a better rendering of its own.
        discardSyncedThumbnail(for: blob.hash)
        return .rendered(result)
    }

    /// The decoded rendering in memory at this size or a larger one.
    private nonisolated func cachedRendering(for object: ObjectSnapshot, atLeast size: Int) -> DecodedThumbnail? {
        for candidate in Self.renderSizes where candidate >= size {
            let key = object.blob.map { Self.renderedKey(for: $0.hash, size: candidate) }
                ?? linkMemoryKey(for: object.id, size: candidate)
            if let cached = memory[key] { return cached }
        }
        return nil
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
        try? data.write(to: fileURL(forKey: previewKey(for: id)), options: .atomic)
        // The picture in memory is the one just replaced.
        for size in Self.renderSizes {
            memory[linkMemoryKey(for: id, size: size)] = nil
        }
    }

    public func hasPreviewImage(for id: ObjectID) -> Bool {
        fileManager.fileExists(atPath: fileURL(forKey: previewKey(for: id)).path(percentEncoded: false))
    }

    /// The displayed dimensions of a cached link preview. Older link records
    /// predate persisted dimensions, so this lets the app repair their
    /// masonry proportions without downloading the same image again.
    public func cachedPreviewImageDimensions(for id: ObjectID) -> (width: Int, height: Int)? {
        guard let data = Self.read(fileURL(forKey: previewKey(for: id))),
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

    private nonisolated func previewKey(for id: ObjectID) -> String {
        "link-\(id.uuid.uuidString)"
    }

    /// A link preview is stored once, as downloaded, and decoded at whatever
    /// size is asked for — so in memory it is kept per size.
    private nonisolated func linkMemoryKey(for id: ObjectID, size: Int) -> String {
        "\(previewKey(for: id))-\(size)"
    }

    /// Cached apart from rendered thumbnails: a borrowed picture is smaller
    /// than one this device would make, and must not satisfy a later request
    /// for the real thing.
    private nonisolated func syncedKey(for hash: ContentHash) -> String {
        "synced-\(hash.hexValue)"
    }

    /// Fetches the travelling rendering once, then serves it from disk. Keyed
    /// by content hash on the way out so two objects sharing a blob share the
    /// borrowed picture too, exactly as they share a rendered one.
    private func syncedThumbnail(for id: ObjectID, hash: ContentHash) async -> Data? {
        let key = syncedKey(for: hash)
        if let cached = Self.read(fileURL(forKey: key, extension: syncedFileExtension)) { return cached }
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
        memory[syncedKey(for: hash)] = nil
        try? fileManager.removeItem(
            at: fileURL(forKey: syncedKey(for: hash), extension: syncedFileExtension)
        )
    }

    /// Synced payloads are PNG or JPEG depending on the picture, so the cache
    /// file does not claim a format it may not hold.
    private nonisolated let syncedFileExtension = "thumb"

    /// Local renderings are JPEG or PNG too, for the same reason.
    private nonisolated let renderedFileExtension = "thumb"

    private func isOriginalPresent(_ blob: BlobDescriptor) -> Bool {
        blobStore?.isAvailableLocally(blob) ?? false
    }

    /// Discards every cached thumbnail. Safe at any time: they regenerate.
    public func clear() throws {
        memory.removeAll()
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

    /// Link previews keep their historical name: they are downloads, not
    /// renderings, and nothing about how they are stored has changed.
    private nonisolated func fileURL(forKey key: String, extension ext: String = "png") -> URL {
        directory.appending(path: "\(key).\(ext)")
    }

    /// A missing file is the common case on a first visit, so it is not
    /// treated as an error.
    private static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// One generator for every type. Quick Look already knows how to render
    /// images, PDFs, video frames and most documents, so the app does not need
    /// a renderer per media type.
    ///
    /// The picture Quick Look hands back is already a bitmap, so it is kept as
    /// the decoded thumbnail rather than read back from the file just written.
    @concurrent
    private static func renderAndSave(source: URL, size: Int, to destination: URL) async -> Rendering? {
        let request = QLThumbnailGenerator.Request(
            fileAt: source,
            size: CGSize(width: size, height: size),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.cgImage
        guard image.width > 0, image.height > 0,
              let data = encodedForDisk(image)
        else { return nil }
        try? data.write(to: destination, options: .atomic)
        let thumbnail = DecodedThumbnail(
            image: image,
            aspectRatio: Double(image.width) / Double(image.height),
            traits: ThumbnailTraits.analyze(image),
            isBorrowed: false
        )
        return Rendering(thumbnail: thumbnail, data: data)
    }

    /// JPEG, a fraction of the size of PNG for a photograph, unless the
    /// picture genuinely uses transparency, which JPEG would fill with black.
    static func encodedForDisk(_ image: CGImage) -> Data? {
        if ThumbnailTraits.hasTransparency(image) {
            return pngData(from: image)
        }
        return jpegData(from: image, quality: 0.8)
    }

    /// Sweeps up renderings named under the old scheme, one per pixel size and
    /// always PNG. Nothing reads them any more, and on a library that has been
    /// browsed at many sizes they add up.
    private static func removeLegacyRenderings(in directory: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else {
            return
        }
        for name in names where isLegacyRendering(name) {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }

    /// A content hash, a dash and a pixel size, as PNG — and nothing else, so
    /// link previews and borrowed pictures are left alone.
    static func isLegacyRendering(_ name: String) -> Bool {
        guard name.hasSuffix(".png") else { return false }
        let stem = name.dropLast(4)
        let parts = stem.split(separator: "-")
        guard parts.count == 2,
              ContentHash(hexValue: String(parts[0])) != nil,
              Int(parts[1]) != nil
        else { return false }
        return true
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
        if ThumbnailTraits.hasTransparency(image),
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

import Foundation
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Generates and caches preview thumbnails.
///
/// Thumbnails are derived content: disposable, rebuildable, and device-local.
/// They are cached under `Derived/`, keyed by content hash so two objects
/// sharing one blob also share one rendered thumbnail.
public actor ThumbnailStore {
    private let directory: URL
    private let fileManager = FileManager.default
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init(directory: URL) throws {
        self.directory = directory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Returns PNG data for an object's thumbnail, generating it on first ask.
    /// Returns nil when the object has no renderable content, or when its
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
        return result
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

    private func cachedData(forKey key: String) -> Data? {
        let url = directory.appending(path: "\(key).png")
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

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

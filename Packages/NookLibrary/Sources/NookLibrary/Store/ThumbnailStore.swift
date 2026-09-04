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
    /// content is protected — a locked object arrives here with no blob.
    public func thumbnail(for object: ObjectSnapshot, maximumSize: CGFloat = 512) async -> Data? {
        guard object.isContentAccessible, let blob = object.blob else { return nil }
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

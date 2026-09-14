import Foundation
import UniformTypeIdentifiers

public enum BlobStoreError: Error, Sendable, LocalizedError {
    case notFound(ContentHash)
    case notAvailableLocally(ContentHash)
    case unreadableSource(URL)
    case writeFailed(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "The original file has not reached this device yet. Check iCloud and try again."
        case .notAvailableLocally:
            "The original file is still downloading from iCloud."
        case .unreadableSource(let url):
            "Nook couldn't read \(url.lastPathComponent)."
        case .writeFailed(let detail):
            "Nook couldn't save the original file to iCloud: \(detail)"
        }
    }
}

/// Where the immutable bytes live.
///
/// Kept behind a protocol from the first commit because the storage question —
/// everything local now, originals downloaded on demand from iCloud later — is
/// the one decision most likely to force a rewrite if it is baked into the
/// persistence layer. Nothing above this protocol knows whether a blob is on
/// disk, in the cloud, or arriving.
public protocol BlobStore: Sendable {
    /// Copies a file into managed storage, returning its descriptor. The
    /// source is untouched: after import the object no longer depends on it.
    func ingest(contentsOf url: URL, contentType: UTType?) async throws -> BlobDescriptor

    /// Stores bytes already in memory, such as a pasted image.
    func ingest(data: Data, contentType: UTType?) async throws -> BlobDescriptor

    /// The local file URL for a blob, or nil when its bytes are not on this device.
    func localURL(for descriptor: BlobDescriptor) -> URL?

    func isAvailableLocally(_ descriptor: BlobDescriptor) -> Bool

    /// Ensures the bytes are present, downloading if the backing store supports it.
    func materialize(_ descriptor: BlobDescriptor) async throws -> URL

    func read(_ descriptor: BlobDescriptor) async throws -> Data

    /// Removes stored bytes. Only ever called once no durable record refers to them.
    func evict(_ descriptor: BlobDescriptor) async throws
}

/// Identifies stored bytes. Content type travels with the hash because the
/// on-disk filename carries an extension, which Quick Look and the AV stack
/// both rely on to pick a reader.
public struct BlobDescriptor: Hashable, Sendable {
    public let hash: ContentHash
    public let byteSize: Int64
    public let contentTypeIdentifier: String?

    public init(hash: ContentHash, byteSize: Int64, contentTypeIdentifier: String? = nil) {
        self.hash = hash
        self.byteSize = byteSize
        self.contentTypeIdentifier = contentTypeIdentifier
    }

    public var contentType: UTType? {
        contentTypeIdentifier.flatMap(UTType.init(_:))
    }

    /// `<hash>.<ext>` — deterministic, so the path can always be recomputed
    /// from the record without storing it.
    public var storageFilename: String {
        if let ext = contentType?.preferredFilenameExtension {
            return "\(hash.hexValue).\(ext)"
        }
        return hash.hexValue
    }
}

public extension Blob {
    var descriptor: BlobDescriptor? {
        guard let hash = ContentHash(hexValue: contentHash) else { return nil }
        return BlobDescriptor(hash: hash,
                              byteSize: byteSize,
                              contentTypeIdentifier: contentTypeIdentifier)
    }
}

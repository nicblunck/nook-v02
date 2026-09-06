import Foundation
import UniformTypeIdentifiers

/// A content-addressed blob store on the local filesystem.
///
/// Bytes land at `Blobs/<aa>/<bb>/<hash>.<ext>`. Because the path is derived
/// entirely from the hash, two imports of identical bytes converge on one file
/// without any coordination, and a blob record never needs to store a path.
public actor LocalBlobStore: BlobStore {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Paths

    nonisolated func url(for descriptor: BlobDescriptor) -> URL {
        descriptor.hash.shardComponents
            .reduce(directory) { $0.appending(path: $1) }
            .appending(path: descriptor.storageFilename)
    }

    // MARK: BlobStore

    public func ingest(contentsOf source: URL, contentType: UTType?) async throws -> BlobDescriptor {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.isReadableFile(atPath: source.path(percentEncoded: false)) else {
            throw BlobStoreError.unreadableSource(source)
        }

        let hash = try ContentHash.ofFile(at: source)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
        let resolvedType = contentType
            ?? (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType)

        let descriptor = BlobDescriptor(hash: hash,
                                        byteSize: size,
                                        contentTypeIdentifier: resolvedType?.identifier)
        try place(descriptor) { destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return descriptor
    }

    public func ingest(data: Data, contentType: UTType?) async throws -> BlobDescriptor {
        let descriptor = BlobDescriptor(hash: .of(data),
                                        byteSize: Int64(data.count),
                                        contentTypeIdentifier: contentType?.identifier)
        try place(descriptor) { destination in
            try data.write(to: destination, options: .atomic)
        }
        return descriptor
    }

    public nonisolated func localURL(for descriptor: BlobDescriptor) -> URL? {
        let candidate = url(for: descriptor)
        return FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) ? candidate : nil
    }

    public nonisolated func isAvailableLocally(_ descriptor: BlobDescriptor) -> Bool {
        localURL(for: descriptor) != nil
    }

    public func materialize(_ descriptor: BlobDescriptor) async throws -> URL {
        // Everything is local in this implementation; a cloud-backed store
        // would start a download here and wait for it.
        guard let url = localURL(for: descriptor) else {
            throw BlobStoreError.notFound(descriptor.hash)
        }
        return url
    }

    public func read(_ descriptor: BlobDescriptor) async throws -> Data {
        try Data(contentsOf: try await materialize(descriptor))
    }

    public func evict(_ descriptor: BlobDescriptor) async throws {
        guard let url = localURL(for: descriptor) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Helpers

    /// Writes bytes to their content-addressed path, treating an existing file
    /// as success — identical content is identical content.
    private func place(_ descriptor: BlobDescriptor, write: (URL) throws -> Void) throws {
        let destination = url(for: descriptor)
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else { return }

        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try write(destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return
        } catch {
            throw BlobStoreError.writeFailed(underlying: error.localizedDescription)
        }
    }
}

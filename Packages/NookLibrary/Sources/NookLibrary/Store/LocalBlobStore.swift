import Foundation
import UniformTypeIdentifiers

/// A content-addressed blob store that keeps originals in an optional iCloud
/// ubiquitous container while retaining the same local-cache behavior offline.
public actor LocalBlobStore: BlobStore {
    private let directory: URL
    private let fallbackDirectory: URL?
    private let isCloudBacked: Bool

    public init(
        directory: URL,
        fallbackDirectory: URL? = nil,
        isCloudBacked: Bool = false
    ) throws {
        self.directory = directory
        self.fallbackDirectory = fallbackDirectory == directory ? nil : fallbackDirectory
        self.isCloudBacked = isCloudBacked
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Paths

    nonisolated func url(for descriptor: BlobDescriptor) -> URL {
        url(for: descriptor, in: directory)
    }

    private nonisolated func url(for descriptor: BlobDescriptor, in directory: URL) -> URL {
        descriptor.hash.shardComponents
            .reduce(directory) { $0.appending(path: $1) }
            .appending(path: descriptor.storageFilename)
    }

    private nonisolated func fallbackURL(for descriptor: BlobDescriptor) -> URL? {
        fallbackDirectory.map { url(for: descriptor, in: $0) }
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

        let descriptor = BlobDescriptor(
            hash: hash,
            byteSize: size,
            contentTypeIdentifier: resolvedType?.identifier
        )
        try place(descriptor) { destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return descriptor
    }

    public func ingest(data: Data, contentType: UTType?) async throws -> BlobDescriptor {
        let descriptor = BlobDescriptor(
            hash: .of(data),
            byteSize: Int64(data.count),
            contentTypeIdentifier: contentType?.identifier
        )
        try place(descriptor) { destination in
            try data.write(to: destination, options: .atomic)
        }
        return descriptor
    }

    public nonisolated func localURL(for descriptor: BlobDescriptor) -> URL? {
        [url(for: descriptor), fallbackURL(for: descriptor)]
            .compactMap { $0 }
            .first(where: isAvailableLocally)
    }

    private nonisolated func isAvailableLocally(_ candidate: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) else {
            return false
        }
        guard let values = try? candidate.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]),
        values.isUbiquitousItem == true else {
            return true
        }

        return values.ubiquitousItemDownloadingStatus == .current
    }

    public nonisolated func isAvailableLocally(_ descriptor: BlobDescriptor) -> Bool {
        localURL(for: descriptor) != nil
    }

    public func materialize(_ descriptor: BlobDescriptor) async throws -> URL {
        let candidate = url(for: descriptor)
        if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            guard let fallback = fallbackURL(for: descriptor),
                  FileManager.default.fileExists(atPath: fallback.path(percentEncoded: false)) else {
                throw BlobStoreError.notFound(descriptor.hash)
            }

            // Originals imported before iCloud storage was enabled still live in
            // the app-group library. Copy one into the preferred store on first
            // use, retaining the old file as a safe fallback until migration is
            // known to have succeeded.
            do {
                try place(descriptor) { temporary in
                    try FileManager.default.copyItem(at: fallback, to: temporary)
                }
            } catch {
                return fallback
            }
        }

        if isCloudBacked,
           let values = try? candidate.resourceValues(forKeys: [
               .isUbiquitousItemKey,
               .ubiquitousItemDownloadingStatusKey
           ]),
           values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: candidate)
            for _ in 0..<600 {
                if let local = localURL(for: descriptor) {
                    return local
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        guard let local = localURL(for: descriptor) else {
            throw BlobStoreError.notFound(descriptor.hash)
        }
        return local
    }

    public func read(_ descriptor: BlobDescriptor) async throws -> Data {
        try Data(contentsOf: try await materialize(descriptor))
    }

    public func evict(_ descriptor: BlobDescriptor) async throws {
        for candidate in [url(for: descriptor), fallbackURL(for: descriptor)].compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) else {
                continue
            }
            try FileManager.default.removeItem(at: candidate)
        }
    }

    // MARK: Helpers

    /// Writes locally first, then moves the completed file into iCloud. This
    /// prevents other devices from seeing a partially written asset.
    private func place(
        _ descriptor: BlobDescriptor,
        write: (URL) throws -> Void
    ) throws {
        let destination = url(for: descriptor)
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            return
        }

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "NookBlob-\(UUID().uuidString)-\(descriptor.storageFilename)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try write(temporary)

            if isCloudBacked {
                try FileManager.default.setUbiquitous(
                    true,
                    itemAt: temporary,
                    destinationURL: destination
                )
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return
        } catch {
            throw BlobStoreError.writeFailed(underlying: error.localizedDescription)
        }
    }
}

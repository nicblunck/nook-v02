import Foundation
import SwiftData
import UniformTypeIdentifiers

public extension LibraryService {

    /// Brings items into the managed library.
    ///
    /// Each file is copied into content-addressed storage and the object stops
    /// depending on where it came from: moving or deleting the external
    /// original afterwards does not affect it. Identical bytes converge on one
    /// stored copy, but never on one object — the caller is told a duplicate
    /// happened rather than having its import silently merged away.
    @discardableResult
    func importItems(
        _ items: [ImportItem],
        into destination: ImportDestination,
        progress: (@Sendable (ImportProgress) -> Void)? = nil
    ) async -> ImportReport {
        var report = ImportReport()
        let total = items.count

        for (index, item) in items.enumerated() {
            progress?(ImportProgress(completed: index, total: total, currentItemName: displayName(of: item)))
            do {
                report.results.append(try await importItem(item, into: destination))
            } catch {
                report.results.append(.failed(displayName: displayName(of: item),
                                              error: error.localizedDescription))
            }
        }

        progress?(ImportProgress(completed: total, total: total, currentItemName: nil))
        return report
    }

    /// Saves a URL as a link object, optionally enriching it with page
    /// metadata. The live page is not archived.
    @discardableResult
    func importLink(_ url: URL,
                    into destination: ImportDestination,
                    metadata: LinkMetadata? = nil) throws -> ObjectID {
        let object = LibraryObject(kind: .link,
                                   title: metadata?.title ?? url.host() ?? url.absoluteString)
        object.sourceURL = url
        object.linkPageTitle = metadata?.title
        object.linkDescription = metadata?.summary
        object.linkPreviewImageURLString = metadata?.previewImageURL?.absoluteString
        object.linkFaviconURLString = metadata?.faviconURL?.absoluteString
        object.contentTypeIdentifier = UTType.url.identifier
        object.folder = resolveDestination(destination)

        context.insert(object)
        try didMutate()
        return object.id
    }
}

// MARK: - Internals

extension LibraryService {

    func importItem(_ item: ImportItem, into destination: ImportDestination) async throws -> ImportItemResult {
        switch item {
        case .link(let url):
            return .imported(try importLink(url, into: destination))

        case .file(let url, let declaredType):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let filename = url.lastPathComponent
            let contentType = declaredType
                ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            let descriptor = try await blobStore.ingest(contentsOf: url, contentType: contentType)
            let metadata = await MediaMetadata.forImport(url: url, contentType: contentType, filename: filename)
            return try finishImport(descriptor: descriptor,
                                    filename: filename,
                                    contentType: contentType,
                                    metadata: metadata,
                                    destination: destination)

        case .data(let data, let contentType, let suggestedName):
            let filename = suggestedName ?? defaultFilename(for: contentType)
            let descriptor = try await blobStore.ingest(data: data, contentType: contentType)
            // Reading dimensions needs a file; the blob is on disk by now.
            let metadata: MediaMetadata
            if let url = blobStore.localURL(for: descriptor) {
                metadata = await MediaMetadata.forImport(url: url, contentType: contentType, filename: filename)
            } else {
                metadata = MediaMetadata()
            }
            return try finishImport(descriptor: descriptor,
                                    filename: filename,
                                    contentType: contentType,
                                    metadata: metadata,
                                    destination: destination)
        }
    }

    private func finishImport(descriptor: BlobDescriptor,
                              filename: String,
                              contentType: UTType?,
                              metadata: MediaMetadata,
                              destination: ImportDestination) throws -> ImportItemResult {
        let existingBlob = blob(withContentHash: descriptor.hash.hexValue)
        let firstExistingObject = existingBlob?.referencingObjects.first

        let blobRecord: Blob
        if let existingBlob {
            blobRecord = existingBlob
        } else {
            blobRecord = Blob(contentHash: descriptor.hash.hexValue,
                              byteSize: descriptor.byteSize,
                              contentTypeIdentifier: descriptor.contentTypeIdentifier)
            context.insert(blobRecord)
        }

        let kind = ImportClassifier.kind(forContentType: contentType, filename: filename)
        let object = LibraryObject(kind: kind, title: ImportClassifier.title(fromFilename: filename))
        object.originalFilename = filename
        object.contentTypeIdentifier = descriptor.contentTypeIdentifier
        object.byteSize = descriptor.byteSize
        object.pixelWidth = metadata.pixelWidth
        object.pixelHeight = metadata.pixelHeight
        object.duration = metadata.duration
        object.pageCount = metadata.pageCount
        object.dateCreated = metadata.creationDate
        object.blob = blobRecord
        object.folder = resolveDestination(destination)

        context.insert(object)
        try didMutate()

        if let firstExistingObject {
            return .importedSharingExistingContent(object.id, existing: firstExistingObject.id)
        }
        return .imported(object.id)
    }

    func resolveDestination(_ destination: ImportDestination) -> Folder? {
        switch destination {
        case .root: nil
        case .folder(let id): folder(withIdentifier: id.uuid)
        }
    }

    func displayName(of item: ImportItem) -> String {
        switch item {
        case .file(let url, _): url.lastPathComponent
        case .data(_, let type, let name): name ?? defaultFilename(for: type)
        case .link(let url): url.absoluteString
        }
    }

    func defaultFilename(for contentType: UTType) -> String {
        let ext = contentType.preferredFilenameExtension.map { ".\($0)" } ?? ""
        return "Untitled\(ext)"
    }
}

extension MediaMetadata {
    static func forImport(url: URL, contentType: UTType?, filename: String) async -> MediaMetadata {
        let kind = ImportClassifier.kind(forContentType: contentType, filename: filename)
        return await MediaMetadataReader.read(from: url, kind: kind)
    }
}

/// Page metadata for a saved link. Fetched by the app layer, which owns the
/// networking, and handed to the library as plain values.
public struct LinkMetadata: Sendable, Hashable {
    public var title: String?
    public var summary: String?
    public var previewImageURL: URL?
    public var faviconURL: URL?

    public init(title: String? = nil,
                summary: String? = nil,
                previewImageURL: URL? = nil,
                faviconURL: URL? = nil) {
        self.title = title
        self.summary = summary
        self.previewImageURL = previewImageURL
        self.faviconURL = faviconURL
    }
}

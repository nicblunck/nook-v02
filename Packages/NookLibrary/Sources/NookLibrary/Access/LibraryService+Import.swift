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
        let pageTitle = LinkNaming.normalized(metadata?.title)
        let object = LibraryObject(kind: .link,
                                   title: LinkNaming.title(pageTitle: pageTitle, url: url))
        object.sourceURL = url
        object.linkPageTitle = pageTitle
        object.linkDescription = metadata?.summary
        object.linkPreviewImageURLString = metadata?.previewImageURL?.absoluteString
        object.linkFaviconURLString = metadata?.faviconURL?.absoluteString
        object.pixelWidth = metadata?.previewPixelWidth
        object.pixelHeight = metadata?.previewPixelHeight
        object.contentTypeIdentifier = UTType.url.identifier
        object.folder = resolveDestination(destination)

        context.insert(object)
        try didMutate()
        return object.id
    }
}

public extension LibraryService {

    /// Saved links that have not been enriched with page metadata yet.
    ///
    /// The share sheet fetches this itself before saving, but a slow network
    /// or an offline share can leave a link with nothing but its URL, so the
    /// app sweeps for stragglers and fills them in afterwards.
    func linksAwaitingMetadata(limit: Int = 10) -> [ObjectID] {
        let linkKind = ObjectKind.link.rawValue
        var descriptor = FetchDescriptor<LibraryObject>(
            predicate: #Predicate { $0.kindRaw == linkKind && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]
        )
        descriptor.fetchLimit = 200

        return ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.linkPageTitle == nil && $0.sourceURLString != nil }
            .prefix(limit)
            .map(\.id)
    }

    /// Renames links still shown under a stand-in taken from their URL even
    /// though the page's own title is already recorded.
    ///
    /// Those are links saved before the naming order settled — the page title
    /// arrived and was stored, but the name on the card stayed as the domain or
    /// the raw address. A name the person chose is left alone: only Nook's own
    /// stand-ins are replaced.
    @discardableResult
    func renameLinksStillNamedAfterTheirURL() throws -> [ObjectID] {
        let linkKind = ObjectKind.link.rawValue
        let descriptor = FetchDescriptor<LibraryObject>(
            predicate: #Predicate { $0.kindRaw == linkKind && $0.deletedAt == nil }
        )

        var renamed: [ObjectID] = []
        for object in (try? context.fetch(descriptor)) ?? [] {
            guard let pageTitle = LinkNaming.normalized(object.linkPageTitle),
                  LinkNaming.isPlaceholder(object.title, for: object.sourceURL),
                  object.title != pageTitle
            else { continue }
            object.title = pageTitle
            renamed.append(object.id)
        }

        guard !renamed.isEmpty else { return [] }
        try didMutate()
        return renamed
    }

    /// Links whose saved metadata says the page offers a representative
    /// picture. The picture itself is derived, device-local data, so every
    /// device uses this list to rebuild any preview absent from its cache.
    func linksAdvertisingPreviewImage() -> [ObjectID] {
        let linkKind = ObjectKind.link.rawValue
        let descriptor = FetchDescriptor<LibraryObject>(
            predicate: #Predicate { $0.kindRaw == linkKind && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]
        )

        return ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.linkPreviewImageURLString != nil && $0.sourceURLString != nil }
            .map(\.id)
    }

    /// Applies fetched page metadata. The title is only replaced while it is
    /// still the stand-in taken from the URL, so a title the user has edited is
    /// never overwritten by a later fetch.
    func applyLinkMetadata(_ metadata: LinkMetadata, to id: ObjectID) throws {
        guard let object = object(withIdentifier: id.uuid) else {
            throw LibraryError.objectNotFound(id)
        }
        let pageTitle = LinkNaming.normalized(metadata.title)

        object.linkPageTitle = pageTitle
        object.linkDescription = metadata.summary
        object.linkPreviewImageURLString = metadata.previewImageURL?.absoluteString
        object.linkFaviconURLString = metadata.faviconURL?.absoluteString
        if let width = metadata.previewPixelWidth,
           let height = metadata.previewPixelHeight,
           width > 0, height > 0 {
            object.pixelWidth = width
            object.pixelHeight = height
        }

        if let pageTitle, LinkNaming.isPlaceholder(object.title, for: object.sourceURL) {
            object.title = pageTitle
        }
        try didMutate()
    }

    /// Records the display dimensions of a link's disposable preview without
    /// replacing any page metadata that may already have synced successfully.
    func applyLinkPreviewDimensions(width: Int, height: Int, to id: ObjectID) throws {
        guard width > 0, height > 0 else { return }
        guard let object = object(withIdentifier: id.uuid) else {
            throw LibraryError.objectNotFound(id)
        }
        object.pixelWidth = width
        object.pixelHeight = height
        try didMutate()
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
        case .link(let url): LinkNaming.siteName(for: url)
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
    public var previewPixelWidth: Int?
    public var previewPixelHeight: Int?

    public init(title: String? = nil,
                summary: String? = nil,
                previewImageURL: URL? = nil,
                faviconURL: URL? = nil,
                previewPixelWidth: Int? = nil,
                previewPixelHeight: Int? = nil) {
        self.title = title
        self.summary = summary
        self.previewImageURL = previewImageURL
        self.faviconURL = faviconURL
        self.previewPixelWidth = previewPixelWidth
        self.previewPixelHeight = previewPixelHeight
    }
}

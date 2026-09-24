import Foundation
import SwiftData
import UniformTypeIdentifiers

public extension LibraryService {

    /// Text extracted from an object's original, if any has been produced.
    ///
    /// Reading derived content passes the same privacy check as reading the
    /// original: a summary of a locked document is still the locked document.
    func extractedText(for id: ObjectID, in access: AccessContext = .standard) throws -> String? {
        guard let object = object(withIdentifier: id.uuid) else {
            throw LibraryError.objectNotFound(id)
        }
        guard broker.allowsContent(of: PrivacyResolver.effectivePrivacy(of: object), in: access) else {
            throw LibraryError.contentNotPermitted(.object(id))
        }
        return object.derived
            .first { $0.kind == .extractedText }?
            .textValue
    }

    /// Objects whose text has not been extracted yet, oldest first.
    ///
    /// Privacy plays no part here: extraction is the library processing content
    /// it already owns, below the broker rather than above it. What the result
    /// can be *read* through is a separate question, enforced on the way out.
    func objectsAwaitingTextExtraction(limit: Int = 20) -> [ObjectID] {
        var descriptor = FetchDescriptor<LibraryObject>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.dateAdded, order: .forward)]
        )
        descriptor.fetchLimit = 500

        let candidates = (try? context.fetch(descriptor)) ?? []
        return candidates
            .filter { object in
                guard object.blob != nil else { return false }
                let contentType = object.contentTypeIdentifier.flatMap(UTType.init(_:))
                guard ContentExtractor.canExtract(kind: object.kind, contentType: contentType) else {
                    return false
                }
                return !object.derived.contains { $0.kind == .extractedText }
            }
            .prefix(limit)
            .map(\.id)
    }

    /// Extracts and stores text for one object. Returns false when there was
    /// nothing to extract, so a caller can stop asking.
    @discardableResult
    func extractText(for id: ObjectID) async throws -> Bool {
        guard let subject = object(withIdentifier: id.uuid) else {
            throw LibraryError.objectNotFound(id)
        }
        guard let descriptor = subject.blob?.descriptor else { return false }

        let kind = subject.kind
        let contentType = subject.contentTypeIdentifier.flatMap(UTType.init(_:))
        guard ContentExtractor.canExtract(kind: kind, contentType: contentType) else { return false }

        let url = try await blobStore.materialize(descriptor)
        guard let text = ContentExtractor.extractText(from: url, kind: kind, contentType: contentType) else {
            return false
        }

        // Re-resolve: the await above means the object could have been deleted
        // while the file was being read.
        guard let current = object(withIdentifier: id.uuid) else { return false }
        let record = DerivedContent(
            kind: .extractedText,
            object: current,
            textValue: text,
            generatorIdentifier: ContentExtractor.identifier
        )
        context.insert(record)
        try didMutate()
        return true
    }

    /// Works through the backlog. Safe to call repeatedly; it does nothing when
    /// there is nothing waiting.
    func extractPendingText(limit: Int = 20) async {
        for id in objectsAwaitingTextExtraction(limit: limit) {
            _ = try? await extractText(for: id)
        }
    }

    /// Discards derived content so it can be produced again — after an
    /// extractor change, or to reclaim space. The originals are untouched.
    func discardDerivedContent(_ kinds: Set<DerivedContentKind> = Set(DerivedContentKind.allCases)) throws {
        let records = (try? context.fetch(FetchDescriptor<DerivedContent>())) ?? []
        for record in records where kinds.contains(record.kind) {
            context.delete(record)
        }
        try didMutate()
    }
}

// MARK: - Synced thumbnails

/// A small rendering of an object, produced once by a device that holds the
/// original and carried to the others with the metadata.
///
/// Originals are deliberately absent from the schema so that they can download
/// on demand — but that leaves every other device with a record and no picture
/// until a file arrives over a different sync system entirely. A few tens of
/// kilobytes travelling with the record closes that gap: the item looks like
/// itself the moment it appears, whether or not its original ever downloads.
public extension LibraryService {

    /// The travelling rendering for an object, if one has been produced.
    ///
    /// Read through the same privacy check as the original: a small picture of
    /// a locked document still shows the locked document.
    func syncedThumbnailData(for id: ObjectID, in access: AccessContext = .standard) throws -> Data? {
        guard let object = object(withIdentifier: id.uuid) else {
            throw LibraryError.objectNotFound(id)
        }
        guard broker.allowsContent(of: PrivacyResolver.effectivePrivacy(of: object), in: access) else {
            throw LibraryError.contentNotPermitted(.object(id))
        }
        return object.derived
            .first { $0.kind == .thumbnail }?
            .dataValue
    }

    /// Objects that still need a travelling rendering, newest first — what was
    /// saved a moment ago is what another device is waiting to see.
    ///
    /// Only objects whose original is *already* on this device qualify. A Mac
    /// must never pull down a whole video to produce a picture the phone that
    /// imported it can make for free.
    func objectsAwaitingThumbnailSync(limit: Int = 20) -> [ObjectID] {
        var descriptor = FetchDescriptor<LibraryObject>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]
        )
        descriptor.fetchLimit = 500

        let candidates = (try? context.fetch(descriptor)) ?? []
        return candidates
            .filter { object in
                guard let descriptor = object.blob?.descriptor else { return false }
                guard !object.derived.contains(where: { $0.kind == .thumbnail }) else { return false }
                return blobStore.isAvailableLocally(descriptor)
            }
            .prefix(limit)
            .map(\.id)
    }

    /// Produces and stores one object's travelling rendering. Returns false
    /// when there was nothing to render, having recorded that fact so no
    /// device asks again.
    @discardableResult
    func generateSyncedThumbnail(for id: ObjectID, using thumbnails: ThumbnailStore) async throws -> Bool {
        guard let subject = object(withIdentifier: id.uuid) else {
            throw LibraryError.objectNotFound(id)
        }
        guard let descriptor = subject.blob?.descriptor else { return false }
        guard !subject.derived.contains(where: { $0.kind == .thumbnail }) else { return false }
        guard blobStore.isAvailableLocally(descriptor) else { return false }

        let url = try await blobStore.materialize(descriptor)
        let data = await thumbnails.renderSyncedThumbnail(from: url)

        // Re-resolve: the await above means the object could have been deleted
        // while the picture was being made.
        guard let current = object(withIdentifier: id.uuid) else { return false }
        guard !current.derived.contains(where: { $0.kind == .thumbnail }) else { return false }

        // A nil payload is a tombstone. Quick Look found nothing renderable in
        // this file, and recording that is what stops every device retrying it
        // on every sync for the life of the library.
        let record = DerivedContent(
            kind: .thumbnail,
            object: current,
            dataValue: data,
            generatorIdentifier: ThumbnailStore.syncedGeneratorIdentifier,
            isDeviceLocal: false
        )
        context.insert(record)
        try didMutate()
        return data != nil
    }

    /// Works through the backlog. Safe to call repeatedly; it does nothing
    /// when there is nothing waiting.
    func generatePendingSyncedThumbnails(
        using thumbnails: ThumbnailStore,
        limit: Int = 20
    ) async {
        for id in objectsAwaitingThumbnailSync(limit: limit) {
            guard !Task.isCancelled else { break }
            _ = try? await generateSyncedThumbnail(for: id, using: thumbnails)
        }
    }
}

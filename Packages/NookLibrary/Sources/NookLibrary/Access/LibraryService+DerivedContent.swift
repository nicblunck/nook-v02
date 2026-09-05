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

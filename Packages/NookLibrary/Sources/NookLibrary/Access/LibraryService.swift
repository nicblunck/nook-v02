import Foundation
import SwiftData

/// The Library Access API: the one way in and out of the library.
///
/// It sits between the persistence layer and every consumer — the SwiftUI app,
/// App Intents, Spotlight, the MCP adapter, model providers — and none of them
/// touch SwiftData directly. Two things follow from that. Privacy is decided
/// once, below all of them, so no integration can reach a row the UI would have
/// hidden. And every operation here is expressible without SwiftUI, which is
/// what makes the same surface usable from an intent or a tool call.
///
/// Reads return `Sendable` snapshots; models never leave the actor.
public actor LibraryService {
    public nonisolated let modelContainer: ModelContainer
    private let executor: any SerialModelExecutor
    let blobStore: any BlobStore
    let broker = PrivacyBroker()

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    var context: ModelContext { executor.modelContext }

    public init(modelContainer: ModelContainer, blobStore: any BlobStore) {
        self.modelContainer = modelContainer
        let modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = false
        self.executor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.blobStore = blobStore
    }

    // MARK: Saving

    func save() throws {
        guard context.hasChanges else { return }
        try context.save()
    }

    /// Bumped after every mutation so observers can refresh without SwiftData
    /// change notifications leaking model objects across the actor boundary.
    public private(set) var revision: Int = 0

    func didMutate() throws {
        try save()
        revision &+= 1
    }

    // MARK: Model lookup

    func object(withIdentifier identifier: UUID) -> LibraryObject? {
        var descriptor = FetchDescriptor<LibraryObject>(
            predicate: #Predicate { $0.identifier == identifier }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func folder(withIdentifier identifier: UUID) -> Folder? {
        var descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.identifier == identifier }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func collection(withIdentifier identifier: UUID) -> LibraryCollection? {
        var descriptor = FetchDescriptor<LibraryCollection>(
            predicate: #Predicate { $0.identifier == identifier }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func tag(withIdentifier identifier: UUID) -> Tag? {
        var descriptor = FetchDescriptor<Tag>(
            predicate: #Predicate { $0.identifier == identifier }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func objects(withIdentifiers identifiers: [UUID]) -> [LibraryObject] {
        identifiers.compactMap { object(withIdentifier: $0) }
    }

    func blob(withContentHash hash: String) -> Blob? {
        var descriptor = FetchDescriptor<Blob>(
            predicate: #Predicate { $0.contentHash == hash }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

public enum LibraryError: Error, Sendable, LocalizedError {
    case objectNotFound(ObjectID)
    case folderNotFound(FolderID)
    case collectionNotFound(CollectionID)
    case tagNotFound(TagID)
    case contentNotPermitted(LibraryReference)
    case invalidFolderMove(reason: String)
    case unsupportedContent(String)

    public var errorDescription: String? {
        switch self {
        case .objectNotFound: "That item is no longer in the library."
        case .folderNotFound: "That folder is no longer in the library."
        case .collectionNotFound: "That collection is no longer in the library."
        case .tagNotFound: "That tag is no longer in the library."
        case .contentNotPermitted: "This content is protected."
        case .invalidFolderMove(let reason): reason
        case .unsupportedContent(let detail): detail
        }
    }
}

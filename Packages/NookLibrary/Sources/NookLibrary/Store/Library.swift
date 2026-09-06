import Foundation
import SwiftData

/// How the library's metadata reaches other devices.
///
/// The schema has been CloudKit-shaped from the first commit — no unique
/// constraints, defaults or optionals throughout, optional relationships with
/// explicit inverses — so turning mirroring on is this switch rather than a
/// migration.
///
/// Turning it on needs a CloudKit container provisioned under the developer
/// account and the iCloud entitlement added to the app targets; until then the
/// app runs fully on `.local`. Note that mirroring covers the *metadata* store
/// only. Originals deliberately do not live in it — they sit behind
/// `BlobStore`, which is what will let metadata and thumbnails reach every
/// device without dragging every original along with them.
public enum LibrarySyncMode: Sendable, Equatable {
    case local
    case cloudKit(containerIdentifier: String)
}

/// A ready-to-use library: persistence, blob storage, thumbnails and the
/// access API, wired together.
///
/// Everything the app touches hangs off this one value, which keeps the
/// composition in a single place rather than spread through view code.
public struct Library: Sendable {
    public let locations: LibraryLocations
    public let service: LibraryService
    public let blobStore: LocalBlobStore
    public let thumbnails: ThumbnailStore

    public static func bootstrap(
        locations: LibraryLocations,
        syncMode: LibrarySyncMode = .local
    ) async throws -> Library {
        try locations.createDirectories()

        let configuration: ModelConfiguration = switch syncMode {
        case .local:
            ModelConfiguration(url: locations.storeURL)
        case .cloudKit(let identifier):
            ModelConfiguration(url: locations.storeURL, cloudKitDatabase: .private(identifier))
        }
        let container = try ModelContainer(for: LibrarySchema.current, configurations: configuration)

        let blobStore = try LocalBlobStore(directory: locations.blobsURL)
        let thumbnails = try ThumbnailStore(directory: locations.thumbnailsURL)
        await thumbnails.attach(blobStore: blobStore)

        return Library(
            locations: locations,
            service: LibraryService(modelContainer: container, blobStore: blobStore),
            blobStore: blobStore,
            thumbnails: thumbnails
        )
    }

    /// An empty library that leaves nothing behind. Used by tests and previews.
    public static func inMemory() async throws -> Library {
        let locations = LibraryLocations.temporary()
        try locations.createDirectories()

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LibrarySchema.current, configurations: configuration)

        let blobStore = try LocalBlobStore(directory: locations.blobsURL)
        let thumbnails = try ThumbnailStore(directory: locations.thumbnailsURL)
        await thumbnails.attach(blobStore: blobStore)

        return Library(
            locations: locations,
            service: LibraryService(modelContainer: container, blobStore: blobStore),
            blobStore: blobStore,
            thumbnails: thumbnails
        )
    }
}

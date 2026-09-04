import Foundation
import SwiftData

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

    public static func bootstrap(locations: LibraryLocations) async throws -> Library {
        try locations.createDirectories()

        let configuration = ModelConfiguration(url: locations.storeURL)
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

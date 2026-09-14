import Foundation
import SwiftData

/// How the library's metadata reaches other devices.
public enum LibrarySyncMode: Sendable, Equatable {
    case local
    case cloudKit(containerIdentifier: String)
}

/// A ready-to-use library: persistence, blob storage, thumbnails and the
/// access API, wired together.
public struct Library: Sendable {
    /// The private CloudKit container used by all Nook app targets.
    public static let defaultCloudKitContainerIdentifier = "iCloud.com.nicolasblunck.nook.app"

    public let locations: LibraryLocations
    public let service: LibraryService
    public let blobStore: LocalBlobStore
    public let thumbnails: ThumbnailStore

    public static func bootstrap(
        locations: LibraryLocations,
        syncMode: LibrarySyncMode = .cloudKit(containerIdentifier: defaultCloudKitContainerIdentifier)
    ) async throws -> Library {
        try locations.createDirectories()

        let configuration: ModelConfiguration = switch syncMode {
        case .local:
            ModelConfiguration(url: locations.storeURL)
        case .cloudKit(let identifier):
            ModelConfiguration(url: locations.storeURL, cloudKitDatabase: .private(identifier))
        }
        let container = try ModelContainer(for: LibrarySchema.current, configurations: configuration)

        let blobStore = try LocalBlobStore(
            directory: locations.blobsURL,
            fallbackDirectory: locations.cloudRoot == nil
                ? nil
                : locations.root.appending(path: "Blobs"),
            isCloudBacked: locations.cloudRoot != nil
        )
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

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

import Foundation

/// The on-disk layout of a managed library.
///
/// Durable state and disposable state are kept in separate trees: the store and
/// blobs are the library, while thumbnails and search indexes underneath
/// `Derived` can be deleted at any time and rebuilt.
public struct LibraryLocations: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The default location: `Application Support/<bundle id>/Library`.
    public static func applicationDefault(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.nicolasblunck.nook"
    ) throws -> LibraryLocations {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LibraryLocations(root: support.appending(path: bundleIdentifier).appending(path: "Library"))
    }

    /// An isolated library in a temporary directory, for tests and previews.
    public static func temporary() -> LibraryLocations {
        LibraryLocations(root: URL.temporaryDirectory.appending(path: "NookLibrary-\(UUID().uuidString)"))
    }

    public var storeURL: URL { root.appending(path: "Store/Library.store") }
    public var blobsURL: URL { root.appending(path: "Blobs") }
    public var derivedURL: URL { root.appending(path: "Derived") }
    public var thumbnailsURL: URL { derivedURL.appending(path: "Thumbnails") }
    public var searchIndexURL: URL { derivedURL.appending(path: "Search/index.sqlite") }

    public func createDirectories() throws {
        let manager = FileManager.default
        for url in [storeURL.deletingLastPathComponent(), blobsURL, thumbnailsURL, searchIndexURL.deletingLastPathComponent()] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

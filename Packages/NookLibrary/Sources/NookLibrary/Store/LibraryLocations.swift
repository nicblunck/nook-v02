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

    /// The app group the app and its extensions share, so a share extension
    /// writes into the same library the app reads.
    public static let defaultAppGroupIdentifier = "group.com.nicolasblunck.nook"

    /// The library both the app and its extensions should open.
    ///
    /// Falls back to this process's own Application Support directory when the
    /// group container is unavailable — an unsigned development build, or a
    /// group that is not provisioned yet — so the app still runs rather than
    /// failing to launch over an entitlement.
    public static func shared(
        appGroupIdentifier: String? = defaultAppGroupIdentifier
    ) throws -> LibraryLocations {
        try resolveShared(
            appGroupIdentifier: appGroupIdentifier,
            groupContainer: {
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: $0
                )
            },
            fallback: { try applicationDefault() }
        )
    }

    /// `containerURL` may return a plausible URL to an unsigned or unentitled
    /// process even though that process cannot write there. Prove the group is
    /// usable before choosing it so development builds genuinely fall back.
    static func resolveShared(
        appGroupIdentifier: String?,
        groupContainer: (String) -> URL?,
        fallback: () throws -> LibraryLocations
    ) throws -> LibraryLocations {
        if let appGroupIdentifier,
           let container = groupContainer(appGroupIdentifier) {
            let root = container.appending(path: "Library")
            do {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true
                )
                return LibraryLocations(root: root)
            } catch {
                // The group exists nominally but this process has no usable
                // entitlement for it. Continue with process-local storage.
            }
        }
        return try fallback()
    }

    /// The per-process location: `Application Support/<bundle id>/Library`.
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

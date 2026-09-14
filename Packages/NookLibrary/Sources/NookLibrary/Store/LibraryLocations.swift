import Foundation

/// The on-disk layout of a managed library.
public struct LibraryLocations: Sendable {
    public let root: URL
    public let cloudRoot: URL?

    public init(root: URL, cloudRoot: URL? = nil) {
        self.root = root
        self.cloudRoot = cloudRoot
    }

    /// The app group the app and its extensions share for metadata and coordination.
    public static let defaultAppGroupIdentifier = "group.com.nicolasblunck.nook.app"
    /// The ubiquitous container used for original file bytes.
    public static let defaultUbiquityContainerIdentifier = "iCloud.com.nicolasblunck.nook.app"

    /// The library both the app and its extensions should open.
    public static func shared(
        appGroupIdentifier: String? = defaultAppGroupIdentifier,
        ubiquityContainerIdentifier: String? = defaultUbiquityContainerIdentifier
    ) throws -> LibraryLocations {
        let shared = try resolveShared(
            appGroupIdentifier: appGroupIdentifier,
            groupContainer: {
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: $0
                )
            },
            fallback: { try applicationDefault() }
        )

        guard FileManager.default.ubiquityIdentityToken != nil,
              let ubiquityContainerIdentifier,
              let cloudRoot = FileManager.default.url(
                forUbiquityContainerIdentifier: ubiquityContainerIdentifier
              ) else {
            return shared
        }

        return LibraryLocations(root: shared.root, cloudRoot: cloudRoot)
    }

    /// containerURL may return a plausible URL to an unsigned or unentitled
    /// process even though that process cannot write there. Prove the group is usable
    /// before choosing it so development builds genuinely fall back.
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

    /// The per-process location: Application Support/<bundle id>/Library.
    public static func applicationDefault(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.nicolasblunck.nook.app"
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
    public var blobsURL: URL {
        (cloudRoot ?? root).appending(path: "Blobs")
    }
    public var derivedURL: URL { root.appending(path: "Derived") }
    public var thumbnailsURL: URL { derivedURL.appending(path: "Thumbnails") }
    public var searchIndexURL: URL { derivedURL.appending(path: "Search/index.sqlite") }

    public func createDirectories() throws {
        let manager = FileManager.default
        for url in [
            storeURL.deletingLastPathComponent(),
            blobsURL,
            thumbnailsURL,
            searchIndexURL.deletingLastPathComponent()
        ] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

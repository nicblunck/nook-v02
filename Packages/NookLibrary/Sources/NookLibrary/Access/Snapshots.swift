import Foundation

/// Colour, symbol and emoji for an entity, defaulting to system presentation.
public struct EntityAppearance: Hashable, Sendable {
    public var colorHex: String?
    public var symbolName: String?
    public var emoji: String?

    public static let system = EntityAppearance()

    public init(colorHex: String? = nil, symbolName: String? = nil, emoji: String? = nil) {
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.emoji = emoji
    }
}

/// An immutable, `Sendable` view of an object.
///
/// The UI is handed snapshots rather than `@Model` instances, and never queries
/// SwiftData directly. That is what keeps the privacy broker underneath every
/// consumer: there is no path to a row that has not already been through it.
/// A redacted snapshot simply does not carry the withheld fields, so a view
/// cannot display something it was not given.
public struct ObjectSnapshot: Identifiable, Hashable, Sendable {
    public let id: ObjectID
    public let kind: ObjectKind
    public let title: String
    public let visibility: Visibility

    public let notes: String
    public let originalFilename: String?
    public let contentTypeIdentifier: String?
    public let byteSize: Int64?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let duration: Double?
    public let pageCount: Int?

    public let dateAdded: Date
    public let dateCreated: Date?
    public let deletedAt: Date?

    public let isFavorite: Bool
    public let isHidden: Bool
    public let isLocked: Bool

    public let sourceURL: URL?
    public let sourceDomain: String?
    public let linkPageTitle: String?
    public let linkDescription: String?

    public let folderID: FolderID?
    public let folderName: String?
    public let tags: [TagSnapshot]
    public let collectionIDs: [CollectionID]

    /// Present only when the caller is entitled to the bytes.
    public let blob: BlobDescriptor?
    public let blobAvailability: BlobAvailability?

    public var reference: LibraryReference { .object(id) }
    public var isInInbox: Bool { folderID == nil && deletedAt == nil }
    public var isContentAccessible: Bool { visibility == .full }

    public var aspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelHeight > 0 else { return nil }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

public struct FolderSnapshot: Identifiable, Hashable, Sendable {
    public let id: FolderID
    public let name: String
    public let appearance: EntityAppearance
    public let parentID: FolderID?
    public let subfolderCount: Int
    public let objectCount: Int
    public let isHidden: Bool
    public let isLocked: Bool
    public let visibility: Visibility
    public let dateAdded: Date

    public var reference: LibraryReference { .folder(id) }
}

public struct CollectionSnapshot: Identifiable, Hashable, Sendable {
    public let id: CollectionID
    public let name: String
    public let appearance: EntityAppearance
    public let memberCount: Int
    public let isSmart: Bool
    public let isHidden: Bool
    public let isLocked: Bool
    public let visibility: Visibility
    public let dateAdded: Date

    public var reference: LibraryReference { .collection(id) }
}

public struct TagSnapshot: Identifiable, Hashable, Sendable {
    public let id: TagID
    public let name: String
    public let appearance: EntityAppearance
    public let objectCount: Int

    public var reference: LibraryReference { .tag(id) }
}

/// What a location contains: its subfolders and its objects, already ordered
/// and already filtered for privacy.
public struct LocationContents: Hashable, Sendable {
    public let folders: [FolderSnapshot]
    public let objects: [ObjectSnapshot]

    public static let empty = LocationContents(folders: [], objects: [])

    public init(folders: [FolderSnapshot], objects: [ObjectSnapshot]) {
        self.folders = folders
        self.objects = objects
    }

    public var isEmpty: Bool { folders.isEmpty && objects.isEmpty }
}

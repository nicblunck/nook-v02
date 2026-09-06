import Foundation

/// A durable identifier for a library entity.
///
/// Identity is independent of filename, path, title and sort position, so a
/// reference survives renames and moves. The phantom `Entity` parameter keeps
/// a folder id from being passed where an object id is expected.
public struct LibraryID<Entity>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID

    public init(_ uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        uuid = try container.decode(UUID.self)
    }
}

/// Phantom tags. They exist only to keep a folder id from being passed where
/// an object id is expected; no value of these types is ever created.
public enum ObjectIdentity {}
public enum FolderIdentity {}
public enum CollectionIdentity {}
public enum TagIdentity {}
public enum BlobIdentity {}

public typealias ObjectID = LibraryID<ObjectIdentity>
public typealias FolderID = LibraryID<FolderIdentity>
public typealias CollectionID = LibraryID<CollectionIdentity>
public typealias TagID = LibraryID<TagIdentity>
public typealias BlobID = LibraryID<BlobIdentity>

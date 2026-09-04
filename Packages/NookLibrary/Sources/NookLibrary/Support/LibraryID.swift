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

public enum ObjectEntity {}
public enum FolderEntity {}
public enum CollectionEntity {}
public enum TagEntity {}
public enum BlobEntity {}

public typealias ObjectID = LibraryID<ObjectEntity>
public typealias FolderID = LibraryID<FolderEntity>
public typealias CollectionID = LibraryID<CollectionEntity>
public typealias TagID = LibraryID<TagEntity>
public typealias BlobID = LibraryID<BlobEntity>

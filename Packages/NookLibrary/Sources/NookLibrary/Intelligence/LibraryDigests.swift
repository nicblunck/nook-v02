import Foundation

/// The smallest useful description of an object for a machine consumer.
///
/// Deliberately less than a `ObjectSnapshot`: no filesystem path, no blob, no
/// storage detail. A tool result should carry the minimum that answers the
/// question, and a path is both useless to a model and a way around the
/// library's own access rules.
public struct ObjectDigest: Codable, Sendable, Hashable {
    /// `object://…` — stable across renames and moves.
    public let reference: String
    public let title: String
    public let kind: String
    public let location: String
    public let dateAdded: Date
    public let dateCreated: Date?
    public let tags: [String]
    public let byteSize: Int64?
    public let sourceURL: String?
    /// True when the item is locked and only its outline is being shown.
    /// Objects can no longer be locked in their own right, so in practice
    /// this is always false — an object buried in a locked folder is
    /// excluded from results entirely rather than surfacing here redacted.
    public let isRedacted: Bool

    init(_ snapshot: ObjectSnapshot) {
        reference = snapshot.reference.description
        title = snapshot.title
        kind = snapshot.kind.rawValue
        location = snapshot.folderName ?? "Inbox"
        dateAdded = snapshot.dateAdded
        dateCreated = snapshot.dateCreated
        tags = snapshot.tags.map(\.name)
        byteSize = snapshot.byteSize
        sourceURL = snapshot.sourceURL?.absoluteString
        isRedacted = snapshot.visibility.isRedacted
    }
}

public struct FolderDigest: Codable, Sendable, Hashable {
    public let reference: String
    public let name: String
    public let itemCount: Int
    public let subfolderCount: Int

    init(_ snapshot: FolderSnapshot) {
        reference = snapshot.reference.description
        name = snapshot.name
        itemCount = snapshot.objectCount
        subfolderCount = snapshot.subfolderCount
    }
}

public struct CollectionDigest: Codable, Sendable, Hashable {
    public let reference: String
    public let name: String
    public let memberCount: Int

    init(_ snapshot: CollectionSnapshot) {
        reference = snapshot.reference.description
        name = snapshot.name
        memberCount = snapshot.memberCount
    }
}

public struct TagDigest: Codable, Sendable, Hashable {
    public let reference: String
    public let name: String
    public let itemCount: Int

    init(_ snapshot: TagSnapshot) {
        reference = snapshot.reference.description
        name = snapshot.name
        itemCount = snapshot.objectCount
    }
}

/// What can be read *from* an object, as opposed to about it.
///
/// Carries text and link metadata. It never carries a file path or raw bytes:
/// getting at an original is a separate, explicitly authorised step.
public struct ObjectContent: Codable, Sendable, Hashable {
    public let reference: String
    public let kind: String
    public let title: String
    public let extractedText: String?
    public let linkTitle: String?
    public let linkDescription: String?
    public let linkURL: String?
    /// Says why there is no text, so a consumer stops asking rather than
    /// treating an empty result as a failure.
    public let unavailableReason: String?
}

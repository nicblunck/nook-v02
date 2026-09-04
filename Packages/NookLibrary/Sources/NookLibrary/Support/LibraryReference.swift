import Foundation

/// A machine-readable reference to a library entity, e.g. `object://7C42…`.
///
/// External consumers (App Intents, MCP, model providers) address content with
/// these rather than with paths or titles, and can resolve one back to the same
/// entity after a rename or move.
public enum LibraryReference: Hashable, Sendable, Codable, CustomStringConvertible {
    case object(ObjectID)
    case folder(FolderID)
    case collection(CollectionID)
    case tag(TagID)

    public var scheme: String {
        switch self {
        case .object: "object"
        case .folder: "folder"
        case .collection: "collection"
        case .tag: "tag"
        }
    }

    public var uuid: UUID {
        switch self {
        case .object(let id): id.uuid
        case .folder(let id): id.uuid
        case .collection(let id): id.uuid
        case .tag(let id): id.uuid
        }
    }

    public var description: String { "\(scheme)://\(uuid.uuidString)" }

    public var url: URL {
        URL(string: description)!
    }

    public init?(_ string: String) {
        guard let url = URL(string: string),
              let scheme = url.scheme,
              let host = url.host(),
              let uuid = UUID(uuidString: host)
        else { return nil }

        switch scheme {
        case "object": self = .object(ObjectID(uuid))
        case "folder": self = .folder(FolderID(uuid))
        case "collection": self = .collection(CollectionID(uuid))
        case "tag": self = .tag(TagID(uuid))
        default: return nil
        }
    }
}

import Foundation
import SwiftData

/// A flat, reusable label. Tags do not nest; richer classification comes from
/// combining several tags with filters and search.
@Model
public final class Tag {
    public var identifier: UUID = UUID()
    public var name: String = ""
    public var dateAdded: Date = Date.distantPast

    public var colorHex: String?
    public var symbolName: String?
    public var emoji: String?

    @Relationship(inverse: \LibraryObject.tags)
    public var objects: [LibraryObject]? = []

    public init(identifier: UUID = UUID(), name: String, dateAdded: Date = .now) {
        self.identifier = identifier
        self.name = name
        self.dateAdded = dateAdded
    }

    public var id: TagID { TagID(identifier) }
    public var reference: LibraryReference { .tag(id) }
    public var taggedObjects: [LibraryObject] { objects ?? [] }

    /// Tag names are compared case- and whitespace-insensitively so that
    /// "Typography" and "typography " resolve to one tag.
    public static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var normalizedName: String { Self.normalize(name) }
}

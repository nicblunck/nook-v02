import Foundation
import SwiftData

/// A node in the true storage hierarchy.
///
/// Folders determine location: every object lives in exactly one folder or at
/// the root. Nesting is unlimited. Collections and tags reorganise without
/// moving anything, so a folder move is the only operation that changes where
/// an object actually is.
@Model
public final class Folder {
    public var identifier: UUID = UUID()
    public var name: String = ""
    public var dateAdded: Date = Date.distantPast
    public var sortIndex: Int = 0

    // MARK: Appearance

    public var colorHex: String?
    public var symbolName: String?
    public var emoji: String?

    // MARK: Remembered presentation
    //
    // Nil means this folder has no opinion and follows the global default.
    // A value only appears once the user explicitly asks to remember it.

    public var rememberedPreferencesData: Data?

    // MARK: Privacy

    /// Folder privacy inherits down the true hierarchy and reaches descendants
    /// everywhere they surface, including collections and search results.
    public var isHidden: Bool = false
    public var isLocked: Bool = false

    // MARK: Relationships

    public var parent: Folder?

    @Relationship(deleteRule: .cascade, inverse: \Folder.parent)
    public var children: [Folder]? = []

    @Relationship(deleteRule: .nullify, inverse: \LibraryObject.folder)
    public var objects: [LibraryObject]? = []

    public init(
        identifier: UUID = UUID(),
        name: String,
        parent: Folder? = nil,
        dateAdded: Date = .now
    ) {
        self.identifier = identifier
        self.name = name
        self.parent = parent
        self.dateAdded = dateAdded
    }

    public var id: FolderID { FolderID(identifier) }
    public var reference: LibraryReference { .folder(id) }

    public var privacyFlags: PrivacyFlags {
        PrivacyFlags(isHidden: isHidden, isLocked: isLocked)
    }

    public var childFolders: [Folder] { children ?? [] }
    public var containedObjects: [LibraryObject] { objects ?? [] }

    /// Ancestors nearest-first. Used by the privacy broker to resolve
    /// inherited protection and by the UI to build breadcrumbs.
    public var ancestors: [Folder] {
        var result: [Folder] = []
        var seen: Set<UUID> = [identifier]
        var current = parent
        while let folder = current, !seen.contains(folder.identifier) {
            result.append(folder)
            seen.insert(folder.identifier)
            current = folder.parent
        }
        return result
    }

    public var depth: Int { ancestors.count }

    /// Whether this folder is `other` or sits beneath it. Guards against
    /// dragging a folder into its own subtree.
    public func isDescendant(of other: Folder) -> Bool {
        if identifier == other.identifier { return true }
        return ancestors.contains { $0.identifier == other.identifier }
    }
}

import Foundation
import SwiftData

/// A flat, manual aggregation of objects from anywhere in the library.
///
/// A collection holds references. It does not own its objects, never changes
/// their true folder location, and never contains folders or other collections.
/// Membership is a join record rather than a plain array because manual
/// ordering has to be durable, which an unordered SwiftData relationship
/// cannot promise.
@Model
public final class LibraryCollection {
    public var identifier: UUID = UUID()
    public var name: String = ""
    public var dateAdded: Date = Date.distantPast
    public var sortIndex: Int = 0

    // MARK: Appearance

    public var colorHex: String?
    public var symbolName: String?
    public var emoji: String?

    // MARK: Privacy

    /// Collection privacy protects only this surface. It does not change the
    /// visibility of the underlying objects through their true folder
    /// locations, which is the whole difference from folder privacy.
    public var isHidden: Bool = false
    public var isLocked: Bool = false

    // MARK: Smart collections
    //
    // Manual collections ship first, but the rule payload and saved sort live
    // here from the start so smart collections do not need a schema change.

    public var isSmart: Bool = false
    public var ruleData: Data?

    /// Remembered presentation, nil while the collection follows the global
    /// default. A smart collection's saved sort lives here too.
    public var rememberedPreferencesData: Data?

    @Relationship(deleteRule: .cascade, inverse: \CollectionMembership.collection)
    public var memberships: [CollectionMembership]? = []

    public init(
        identifier: UUID = UUID(),
        name: String,
        isSmart: Bool = false,
        dateAdded: Date = .now
    ) {
        self.identifier = identifier
        self.name = name
        self.isSmart = isSmart
        self.dateAdded = dateAdded
    }

    public var id: CollectionID { CollectionID(identifier) }
    public var reference: LibraryReference { .collection(id) }

    public var privacyFlags: PrivacyFlags {
        PrivacyFlags(isHidden: isHidden, isLocked: isLocked)
    }

    public var orderedMemberships: [CollectionMembership] {
        (memberships ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    public var orderedObjects: [LibraryObject] {
        orderedMemberships.compactMap(\.object)
    }
}

/// One object's place in one collection. Carries the manual sort position.
@Model
public final class CollectionMembership {
    public var identifier: UUID = UUID()
    public var sortIndex: Int = 0
    public var dateAdded: Date = Date.distantPast

    public var collection: LibraryCollection?
    public var object: LibraryObject?

    public init(
        identifier: UUID = UUID(),
        collection: LibraryCollection?,
        object: LibraryObject?,
        sortIndex: Int,
        dateAdded: Date = .now
    ) {
        self.identifier = identifier
        self.collection = collection
        self.object = object
        self.sortIndex = sortIndex
        self.dateAdded = dateAdded
    }
}

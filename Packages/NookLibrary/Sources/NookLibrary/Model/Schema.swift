import Foundation
import SwiftData

/// The persisted schema.
///
/// Three rules are observed throughout so that the same store can later be
/// mirrored to CloudKit without a migration:
///
/// 1. No `.unique` attributes — CloudKit mirroring rejects them. Uniqueness
///    (content hashes, tag names) is enforced in `LibraryService` instead.
/// 2. Every stored property has a default value or is optional.
/// 3. Every relationship is optional, with an explicit inverse and a delete
///    rule that never cascades across an ownership boundary.
///
/// Blob *bytes* are deliberately absent from the schema. They live in a
/// content-addressed `BlobStore`, which is what allows metadata and thumbnails
/// to sync to every device without dragging every original along with them.
public enum LibrarySchema {
    public static let models: [any PersistentModel.Type] = [
        LibraryObject.self,
        Folder.self,
        LibraryCollection.self,
        CollectionMembership.self,
        Tag.self,
        Blob.self,
        DerivedContent.self
    ]

    public static var current: Schema {
        Schema(models)
    }
}

import Foundation
import SwiftData

/// A blob's local presence on *this* device. Cloud existence is a separate
/// question from local availability, which is what lets metadata and
/// thumbnails be everywhere while originals download on demand.
public enum BlobAvailability: String, Codable, Sendable {
    /// The bytes are on this device and can be opened immediately.
    case local
    /// The record is known but the bytes are not here yet.
    case remote
    /// A download is in flight.
    case downloading
    /// The record exists but the bytes could not be found in either place.
    case missing
}

/// The immutable binary payload behind a file-backed object.
///
/// Blobs and objects are separate entities so that several independent objects
/// — each with its own title, tags, location, collections and privacy state —
/// can reference one stored copy of the bytes. The bytes themselves are not
/// stored here; this record points into the content-addressed `BlobStore`.
@Model
public final class Blob {
    public var identifier: UUID = UUID()

    /// Lowercase hex SHA-256 of the original bytes. Uniqueness is enforced in
    /// `LibraryService`, not by a schema constraint, because CloudKit
    /// mirroring does not permit unique attributes.
    public var contentHash: String = ""

    public var byteSize: Int64 = 0
    public var contentTypeIdentifier: String?
    public var dateAdded: Date = Date.distantPast
    public var availabilityRaw: String = BlobAvailability.local.rawValue

    /// Per-device retention rule. Set when the user asks to keep an original,
    /// or a folder or collection containing it, on this device.
    public var isPinnedLocally: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \LibraryObject.blob)
    public var objects: [LibraryObject]? = []

    public init(
        identifier: UUID = UUID(),
        contentHash: String,
        byteSize: Int64,
        contentTypeIdentifier: String? = nil,
        dateAdded: Date = .now,
        availability: BlobAvailability = .local
    ) {
        self.identifier = identifier
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.contentTypeIdentifier = contentTypeIdentifier
        self.dateAdded = dateAdded
        self.availabilityRaw = availability.rawValue
    }

    public var id: BlobID { BlobID(identifier) }

    public var availability: BlobAvailability {
        get { BlobAvailability(rawValue: availabilityRaw) ?? .missing }
        set { availabilityRaw = newValue.rawValue }
    }

    public var referencingObjects: [LibraryObject] { objects ?? [] }

    /// A blob may be collected only once nothing durable points at it —
    /// including objects sitting in the Trash, which can still be put back.
    public var isEligibleForCollection: Bool { referencingObjects.isEmpty }
}

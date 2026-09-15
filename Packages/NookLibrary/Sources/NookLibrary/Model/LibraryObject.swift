import Foundation
import SwiftData

/// The universal record for anything saved in the library.
///
/// One model covers images, video, audio, PDFs, screenshots, links and generic
/// files, so they can coexist in a folder, a collection, a search result or a
/// media-type view without special-casing. Type-specific detail lives in the
/// optional metadata below rather than in parallel entity types.
@Model
public final class LibraryObject {
    /// Durable identity, independent of title, filename and location.
    public var identifier: UUID = UUID()

    public var kindRaw: String = ObjectKind.file.rawValue

    // MARK: User metadata

    public var title: String = ""
    public var notes: String = ""
    public var isFavorite: Bool = false

    // MARK: File metadata

    public var originalFilename: String?
    public var contentTypeIdentifier: String?
    public var byteSize: Int64?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    public var pageCount: Int?

    // MARK: Dates

    public var dateAdded: Date = Date.distantPast
    /// The original creation date where the source told us one.
    public var dateCreated: Date?
    /// Set when the object is sent to Recently Deleted; nil while it is live.
    public var deletedAt: Date?

    // MARK: Source

    public var sourceURLString: String?
    public var sourceDomain: String?

    // MARK: Link metadata

    public var linkPageTitle: String?
    public var linkDescription: String?
    public var linkPreviewImageURLString: String?
    public var linkFaviconURLString: String?

    // MARK: Privacy

    /// Objects cannot be individually locked — only folders can. An object's
    /// effective lock state comes entirely from folder ancestry.
    public var isHidden: Bool = false

    // MARK: Relationships

    /// The one true location. `nil` means the library root, which surfaces in Inbox.
    public var folder: Folder?

    /// The immutable payload. `nil` for objects with no bytes of their own, such as links.
    public var blob: Blob?

    public var tags: [Tag]? = []

    @Relationship(deleteRule: .cascade, inverse: \CollectionMembership.object)
    public var collectionMemberships: [CollectionMembership]? = []

    @Relationship(deleteRule: .cascade, inverse: \DerivedContent.object)
    public var derivedContent: [DerivedContent]? = []

    public init(
        identifier: UUID = UUID(),
        kind: ObjectKind,
        title: String,
        dateAdded: Date = .now
    ) {
        self.identifier = identifier
        self.kindRaw = kind.rawValue
        self.title = title
        self.dateAdded = dateAdded
    }

    // MARK: Derived accessors

    public var id: ObjectID { ObjectID(identifier) }
    public var reference: LibraryReference { .object(id) }

    public var kind: ObjectKind {
        get { ObjectKind(rawValue: kindRaw) ?? .file }
        set { kindRaw = newValue.rawValue }
    }

    public var sourceURL: URL? {
        get { sourceURLString.flatMap(URL.init(string:)) }
        set {
            sourceURLString = newValue?.absoluteString
            sourceDomain = newValue?.host()
        }
    }

    public var isDeleted_: Bool { deletedAt != nil }

    public var privacyFlags: PrivacyFlags {
        PrivacyFlags(isHidden: isHidden, isLocked: false)
    }

    public var tagList: [Tag] { tags ?? [] }
    public var memberships: [CollectionMembership] { collectionMemberships ?? [] }
    public var derived: [DerivedContent] { derivedContent ?? [] }
}

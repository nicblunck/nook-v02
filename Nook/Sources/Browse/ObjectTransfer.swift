import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

/// What a drag carries.
///
/// Inside the app it carries identity, not content: a folder drop relocates,
/// a collection drop only adds a membership. Dragged out to the Finder or
/// another app, the same drag hands over a copy of the original file, so
/// getting something back out is just dragging it.
struct ObjectTransfer: Codable, Transferable, Hashable {
    /// One drag can carry a selected batch, not just the item under the pointer.
    /// The first id remains available for the few call sites that only need a
    /// single item.
    let ids: [ObjectID]

    /// The folder each item came from. This is intentionally part of the
    /// in-app transfer so a canvas can decline a drop that would leave every
    /// item exactly where it already is.
    let sourceFolderIDs: [FolderID?]

    var id: ObjectID { ids[0] }

    /// Resolved at drag time when the bytes are already on this device.
    /// Excluded from the encoded form — it is a local detail, not identity.
    var fileURL: URL?

    private enum CodingKeys: String, CodingKey { case ids, sourceFolderIDs }

    init(id: ObjectID, fileURL: URL? = nil, sourceFolderID: FolderID? = nil) {
        self.ids = [id]
        self.sourceFolderIDs = [sourceFolderID]
        self.fileURL = fileURL
    }

    init(ids: [ObjectID],
         fileURL: URL? = nil,
         sourceFolderIDs: [FolderID?] = []) {
        self.ids = ids
        self.sourceFolderIDs = sourceFolderIDs.count == ids.count
            ? sourceFolderIDs
            : Array(repeating: nil, count: ids.count)
        self.fileURL = fileURL
    }

    var isEmpty: Bool { ids.isEmpty }

    /// Used by a background drop on the currently open folder or Inbox.
    func isAlreadyIn(_ destination: FolderID?) -> Bool {
        !ids.isEmpty
            && sourceFolderIDs.count == ids.count
            && sourceFolderIDs.allSatisfy { $0 == destination }
    }

    static var transferRepresentation: some TransferRepresentation {
        // Identity first, so an in-app drop resolves to the object rather than
        // to a copy of its bytes.
        CodableRepresentation(contentType: .nookObject)

        FileRepresentation(exportedContentType: .item) { transfer in
            guard let url = transfer.fileURL else {
                throw ObjectTransferError.originalNotAvailable
            }
            // The default copies rather than vending the library's own file,
            // which keeps managed storage untouched by whatever receives it.
            return SentTransferredFile(url)
        }
    }
}

/// Folder identity for hierarchy drag-and-drop. Folder drags stay internal to
/// Nook; unlike objects, a folder does not represent an exportable file.
struct FolderTransfer: Codable, Transferable, Hashable {
    let id: FolderID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .nookFolder)
    }
}

enum ObjectTransferError: Error, LocalizedError {
    case originalNotAvailable

    var errorDescription: String? {
        "This item's original isn't available on this device yet."
    }
}

extension UTType {
    static let nookObject = UTType(exportedAs: "com.nicolasblunck.nook.object")
    static let nookFolder = UTType(exportedAs: "com.nicolasblunck.nook.folder")
}

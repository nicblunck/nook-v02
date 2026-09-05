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
    let id: ObjectID

    /// Resolved at drag time when the bytes are already on this device.
    /// Excluded from the encoded form — it is a local detail, not identity.
    var fileURL: URL?

    private enum CodingKeys: String, CodingKey { case id }

    init(id: ObjectID, fileURL: URL? = nil) {
        self.id = id
        self.fileURL = fileURL
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

enum ObjectTransferError: Error, LocalizedError {
    case originalNotAvailable

    var errorDescription: String? {
        "This item's original isn't available on this device yet."
    }
}

extension UTType {
    static let nookObject = UTType(exportedAs: "com.nicolasblunck.nook.object")
}

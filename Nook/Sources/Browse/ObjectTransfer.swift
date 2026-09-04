import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

/// What a drag inside the app carries: identity, not content.
///
/// Dragging moves or files an object by reference, so nothing is copied and
/// the receiving surface decides what the drop means — a folder drop relocates,
/// a collection drop only adds a membership.
struct ObjectTransfer: Codable, Transferable, Hashable {
    let id: ObjectID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .nookObject)
    }
}

extension UTType {
    static let nookObject = UTType(exportedAs: "com.nicolasblunck.nook.object")
}

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
    /// The item that was under the pointer when the drag began.
    ///
    /// Outside Nook a drag is one item — one file arrives in the Finder — so
    /// this is the one whose bytes are vended.
    let id: ObjectID

    /// Everything the drag is carrying: the grabbed item on its own, or the
    /// whole selection it was part of. Dragging one of five selected photos
    /// into a folder moves five, which is what dragging a selection means
    /// everywhere else on the Mac.
    let ids: [ObjectID]

    /// The folder each item came from. This lets a canvas recognize a local
    /// drag that would leave every item exactly where it already is.
    let sourceFolderIDs: [FolderID?]

    /// Resolved at drag time when the bytes are already on this device.
    /// Excluded from the encoded form — it is a local detail, not identity.
    var fileURL: URL?

    /// `carrying` is the selection the grabbed item belongs to. The grabbed
    /// item is always part of what moves, even when it was not selected —
    /// dragging something outside the selection acts on what was dragged.
    private enum CodingKeys: String, CodingKey { case id, ids, sourceFolderIDs }

    init(id: ObjectID,
         carrying selection: [ObjectID] = [],
         fileURL: URL? = nil,
         sourceFolderID: FolderID? = nil) {
        self.id = id
        self.ids = selection.contains(id) ? selection : [id]
        self.sourceFolderIDs = Array(repeating: sourceFolderID, count: self.ids.count)
        self.fileURL = fileURL
    }

    init(ids: [ObjectID],
         fileURL: URL? = nil,
         sourceFolderIDs: [FolderID?] = []) {
        self.id = ids.first ?? ObjectID()
        self.ids = ids
        self.sourceFolderIDs = sourceFolderIDs.count == ids.count
            ? sourceFolderIDs
            : Array(repeating: nil, count: ids.count)
        self.fileURL = fileURL
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedIDs = try container.decodeIfPresent([ObjectID].self, forKey: .ids) ?? []
        let decodedID = try container.decodeIfPresent(ObjectID.self, forKey: .id)
            ?? decodedIDs.first
            ?? ObjectID()
        self.id = decodedID
        self.ids = decodedIDs.isEmpty ? [decodedID] : decodedIDs
        let decodedSources = try container.decodeIfPresent([FolderID?].self, forKey: .sourceFolderIDs) ?? []
        self.sourceFolderIDs = decodedSources.count == self.ids.count
            ? decodedSources
            : Array(repeating: nil, count: self.ids.count)
        self.fileURL = nil
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

/// Anything a library surface can be asked to take.
///
/// One type rather than three drop destinations stacked on the same view. A
/// dragged object also vends a copy of its file, so a destination that took
/// files would take an object drag too and import a second copy of something
/// the library already holds. Listing Nook's own types first is what settles
/// that: the first representation that matches decides what the drag is.
enum LibraryDropItem: Transferable {
    case object(ObjectTransfer)
    case folder(FolderTransfer)
    case file(URL)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (transfer: ObjectTransfer) in Self.object(transfer) })
        ProxyRepresentation(importing: { (transfer: FolderTransfer) in Self.folder(transfer) })
        ProxyRepresentation(importing: { (url: URL) in Self.file(url) })
    }
}

extension Array where Element == LibraryDropItem {
    /// Every object the drag carries, in the order it was picked up and
    /// without repeats — two selected tiles of the same photo on Home name one
    /// object, and moving it twice is moving it once.
    var objectIDs: [ObjectID] {
        var seen: Set<ObjectID> = []
        return flatMap { item -> [ObjectID] in
            if case .object(let transfer) = item { transfer.ids } else { [] }
        }
        .filter { seen.insert($0).inserted }
    }

    var folderIDs: [FolderID] {
        compactMap { if case .folder(let transfer) = $0 { transfer.id } else { nil } }
    }

    var fileURLs: [URL] {
        compactMap { if case .file(let url) = $0 { url } else { nil } }
    }

    var carriesLibraryItems: Bool { !objectIDs.isEmpty || !folderIDs.isEmpty }
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

extension View {
    /// Makes a place take a drop.
    ///
    /// Every surface that names a place — a sidebar row, a folder card, the
    /// canvas itself — goes through here, so what dropping on a collection
    /// means cannot drift from what dropping on a folder means.
    func libraryDropTarget(_ target: DropTarget, model: LibraryModel) -> some View {
        dropDestination(for: LibraryDropItem.self) { items, _ in
            Task { await model.accept(items, at: target) }
            return true
        }
    }
}

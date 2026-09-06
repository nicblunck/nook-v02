import Foundation
import UniformTypeIdentifiers

/// One thing the user asked to bring into the library.
public enum ImportItem: Sendable {
    /// A file on disk. It is copied in; the original is left untouched.
    case file(url: URL, contentType: UTType? = nil)
    /// Bytes already in hand, such as a pasted image.
    case data(Data, contentType: UTType, suggestedName: String?)
    /// A web link, saved as an object in its own right.
    case link(URL)
}

/// Where an import lands. Context-aware by design: importing while inside a
/// folder targets that folder, and everything else goes to the root, where it
/// surfaces in the Inbox.
public enum ImportDestination: Hashable, Sendable {
    case root
    case folder(FolderID)

    public init(scope: LibraryScope) {
        switch scope {
        case .folder(let id), .folderTree(let id): self = .folder(id)
        default: self = .root
        }
    }
}

/// What happened to one item.
public enum ImportItemResult: Sendable {
    case imported(ObjectID)
    /// Byte-identical content was already in the library. A new object was
    /// created and points at the existing blob — no bytes were copied twice,
    /// and nothing was silently merged.
    case importedSharingExistingContent(ObjectID, existing: ObjectID)
    case failed(displayName: String, error: String)

    public var objectID: ObjectID? {
        switch self {
        case .imported(let id), .importedSharingExistingContent(let id, _): id
        case .failed: nil
        }
    }
}

public struct ImportReport: Sendable {
    public var results: [ImportItemResult]

    public init(results: [ImportItemResult] = []) {
        self.results = results
    }

    public var importedIDs: [ObjectID] { results.compactMap(\.objectID) }
    public var failures: [ImportItemResult] {
        results.filter { if case .failed = $0 { true } else { false } }
    }
    public var duplicateCount: Int {
        results.count { if case .importedSharingExistingContent = $0 { true } else { false } }
    }
    public var hasFailures: Bool { !failures.isEmpty }
}

/// Emitted as an import runs, so a large import can show progress without
/// blocking the rest of the app.
public struct ImportProgress: Sendable {
    public var completed: Int
    public var total: Int
    public var currentItemName: String?

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
    public var isFinished: Bool { completed >= total }
}

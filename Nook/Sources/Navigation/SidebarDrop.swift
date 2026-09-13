import Foundation
import UniformTypeIdentifiers
import NookLibrary
#if os(macOS)
import AppKit
#endif

/// What a drag can do where in the sidebar.
///
/// Decided once, for the feedback and for the drop alike, so the row that
/// lights up is always the row that will take it — and so it can be tested
/// without a pointer.
enum SidebarDropRules {
    /// What the drag is carrying.
    ///
    /// A folder drag whose identity could not be read is still a folder drag,
    /// and is offered no folder: the row it started on is the one row it must
    /// never be shown landing in.
    enum Payload: Equatable {
        case folder(FolderID?)
        case objects
        case files
    }

    enum Verdict: Equatable {
        /// The drop relocates: into a folder, or out to the root.
        case move
        /// The drop adds something — a membership, a tag, a star, an import —
        /// and moves nothing.
        case add
        /// The one place a folder cannot go: inside itself.
        case forbidden
        /// The place takes nothing from this drag.
        case nothing

        var takesDrop: Bool { self == .move || self == .add }
    }

    @MainActor
    static func verdict(for payload: Payload, on target: DropTarget, model: LibraryModel) -> Verdict {
        switch (payload, target) {
        case (.folder(let id?), .folder(let parent)):
            return model.folderCanBeDropped(id, into: parent) ? .move : .forbidden
        case (.folder(nil), .folder):
            return .nothing
        case (.folder(_?), .hidden):
            return .move
        // A collection, a tag or Favorites gathers objects. A folder is a
        // place, and a place cannot be gathered.
        case (.folder, _):
            return .nothing
        case (.objects, .folder), (.objects, .trash), (.objects, .hidden):
            return .move
        case (.objects, .collection), (.objects, .tag), (.objects, .favorites):
            return .add
        case (.files, .folder), (.files, .collection), (.files, .tag), (.files, .favorites):
            return .add
        case (.files, .trash), (.files, .hidden):
            return .nothing
        case (_, .currentLocation):
            return .nothing
        }
    }

    #if os(macOS)
    /// What a drag is carrying, read off its pasteboard's own type list.
    ///
    /// Nothing is resolved to answer this. An object dragged out of the canvas
    /// also promises the Finder a file, and a promise must not be opened
    /// before the drop; the type list is free to read, and a folder's identity
    /// is a few bytes of our own JSON.
    static func payload(on pasteboard: NSPasteboard) -> Payload? {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        if types.contains(UTType.nookFolder.identifier) {
            let folder = pasteboard.data(forType: .init(UTType.nookFolder.identifier))
                .flatMap { try? JSONDecoder().decode(FolderTransfer.self, from: $0) }
            return .folder(folder?.id)
        }
        if types.contains(UTType.nookObject.identifier) { return .objects }
        if types.contains(UTType.fileURL.identifier)
            || !types.isDisjoint(with: NSFilePromiseReceiver.readableDraggedTypes) { return .files }
        return nil
    }
    #endif
}

#if os(macOS)
extension LibraryDropItem {
    /// Everything a drop carries, once it has landed.
    ///
    /// Nook's own types are read as the JSON their `Transferable`
    /// representations write, so a drag begun in SwiftUI — an object from the
    /// canvas — reads the same here as it does there. Files come as URLs, or
    /// as promises that are received into a scratch directory first: this is
    /// the drop, the one moment a promise may be kept.
    @MainActor
    static func items(on pasteboard: NSPasteboard) async -> [LibraryDropItem] {
        var items: [LibraryDropItem] = []
        let decoder = JSONDecoder()
        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            if let data = pasteboardItem.data(forType: .init(UTType.nookObject.identifier)),
               let transfer = try? decoder.decode(ObjectTransfer.self, from: data) {
                items.append(.object(transfer))
            } else if let data = pasteboardItem.data(forType: .init(UTType.nookFolder.identifier)),
                      let transfer = try? decoder.decode(FolderTransfer.self, from: data) {
                items.append(.folder(transfer))
            }
        }
        guard items.isEmpty else { return items }

        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        items.append(contentsOf: urls.map { .file($0) })

        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        if !promises.isEmpty {
            let destination = FileManager.default.temporaryDirectory
                .appending(path: "Nook Drop \(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for promise in promises {
                items.append(contentsOf: await promise.receive(into: destination).map { .file($0) })
            }
        }
        return items
    }
}

private extension NSFilePromiseReceiver {
    /// The files a promise delivers, once it has.
    @MainActor
    func receive(into directory: URL) async -> [URL] {
        await withCheckedContinuation { continuation in
            let queue = OperationQueue()
            let received = ReceivedFiles()
            receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
                received.add(error == nil ? url : nil)
            }
            queue.addBarrierBlock {
                continuation.resume(returning: received.urls)
            }
        }
    }
}

/// Collects what a promise's reader hands over, which arrives one file at a
/// time on the promise's own queue.
private final class ReceivedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [URL] = []

    func add(_ url: URL?) {
        guard let url else { return }
        lock.withLock { collected.append(url) }
    }

    var urls: [URL] { lock.withLock { collected } }
}
#endif

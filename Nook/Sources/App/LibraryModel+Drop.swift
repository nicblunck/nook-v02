import Foundation
import NookLibrary

/// Where a drop lands, and therefore what it means.
///
/// Moving, gathering, tagging, favouriting, hiding and throwing away are one
/// gesture aimed at different places. Naming the places rather than writing a
/// handler per row is what keeps them consistent: the sidebar, the canvas and
/// Home all hand a drop to the same list, so what dropping on a collection
/// does cannot drift from what dropping on a folder does.
enum DropTarget: Hashable {
    /// Whatever the gallery in front of the user is showing. Resolved against
    /// the current scope at the moment of the drop, so a modifier declared
    /// once on a gallery means the right thing in every location.
    case currentLocation
    /// A folder, or the library root when nil.
    case folder(FolderID?)
    case collection(CollectionID)
    case tag(TagID)
    case favorites
    case trash
    case hidden
}

@MainActor
extension LibraryModel {

    /// Takes a drop.
    ///
    /// Files are imported; objects and folders already in the library are
    /// filed rather than copied. Anything the drop would not actually change —
    /// an item dragged into the folder it already lives in — is dropped on the
    /// floor here rather than sent to the store to be written unchanged.
    func accept(_ items: [LibraryDropItem], at target: DropTarget) async {
        guard let place = resolvedTarget(target) else { return }

        let files = items.fileURLs
        if !files.isEmpty {
            // Imported straight into the folder when there is one, so the
            // bytes never land somewhere else and get moved a moment later.
            let imported = await importItems(files.map { ImportItem.file(url: $0) },
                                             into: importDestination(for: place))
            if case .folder = place {} else { await file(imported, into: place) }
        }

        let objects = items.objectIDs
        if !objects.isEmpty { await file(objects, into: place) }

        if case .folder(let parent) = place {
            for folder in items.folderIDs where canMoveFolder(folder, to: parent) {
                await moveFolder(folder, to: parent)
            }
        } else if case .hidden = place {
            for folder in items.folderIDs {
                guard let snapshot = folderSnapshot(folder), !snapshot.isExplicitlyHidden else { continue }
                await setHidden(true, forFolder: snapshot)
            }
        }
    }

    // MARK: Filing

    /// Gives objects whatever the place they were dropped on stands for.
    private func file(_ ids: [ObjectID], into place: DropTarget) async {
        let ids = filed(ids, into: place)
        guard !ids.isEmpty else { return }

        switch place {
        case .folder(let parent):
            await move(ids, to: parent)
        case .collection(let id):
            await addToCollection(id, objects: ids)
        case .tag(let id):
            guard let name = tags.first(where: { $0.id == id })?.name else { return }
            await addTag(name, to: ids)
        case .favorites:
            await setFavorite(true, for: ids)
        case .trash:
            await delete(ids)
        case .hidden:
            await setHidden(true, for: snapshots(of: ids))
        case .currentLocation:
            break
        }
    }

    /// The objects the place would actually change, which is what stops a drag
    /// that ends where it started from writing to the store and relaying the
    /// canvas underneath the pointer.
    ///
    /// Only what is on screen can be checked; anything dragged in from
    /// somewhere this window cannot see is let through and settled by the
    /// store.
    private func filed(_ ids: [ObjectID], into place: DropTarget) -> [ObjectID] {
        ids.filter { id in
            guard let object = snapshot(of: id) else { return true }
            switch place {
            case .folder(let parent): return object.folderID != parent
            case .collection(let collection): return !object.collectionIDs.contains(collection)
            case .tag(let tag): return !object.tags.contains { $0.id == tag }
            case .favorites: return !object.isFavorite
            case .trash: return object.deletedAt == nil
            case .hidden: return !object.isExplicitlyHidden
            case .currentLocation: return false
            }
        }
    }

    // MARK: Places

    /// What the gallery in front of the user counts as a place to drop into.
    ///
    /// Recent, All Objects and the media types are queries over the library
    /// rather than places in it, and Home is a way back into recent work: a
    /// drop has nowhere to land in any of them, so it does not land.
    private func resolvedTarget(_ target: DropTarget) -> DropTarget? {
        guard case .currentLocation = target else { return target }
        guard !isShowingHome else { return nil }
        switch scope {
        case .folder(let id), .folderTree(let id): return .folder(id)
        case .inbox: return .folder(nil)
        case .collection(let id): return .collection(id)
        case .tag(let id): return .tag(id)
        case .favorites: return .favorites
        case .recentlyDeleted: return .trash
        case .hidden: return .hidden
        case .allObjects, .recent, .kind: return nil
        }
    }

    private func importDestination(for place: DropTarget) -> ImportDestination {
        if case .folder(let id) = place, let id { return .folder(id) }
        return .root
    }

    /// Whether a folder can become a child of `parent`.
    ///
    /// Moving a folder where it already is changes nothing, so nothing is
    /// written for it.
    private func canMoveFolder(_ id: FolderID, to parent: FolderID?) -> Bool {
        guard folderSnapshot(id)?.parentID != parent else { return false }
        return folderCanBeDropped(id, into: parent)
    }

    /// Whether `parent` is somewhere a folder could go at all.
    ///
    /// A folder cannot be moved inside itself or anything beneath it. The
    /// store refuses that too; refusing it here is what lets the sidebar show
    /// the drop as refused while it is still overhead, rather than take it and
    /// raise an alert.
    func folderCanBeDropped(_ id: FolderID, into parent: FolderID?) -> Bool {
        guard let parent else { return true }
        return !isFolder(parent, atOrUnder: id)
    }

    private func isFolder(_ id: FolderID, atOrUnder ancestor: FolderID) -> Bool {
        var current: FolderID? = id
        // Capped rather than trusted: a cycle introduced by a bad sync would
        // otherwise hang the pointer mid-drag.
        for _ in 0..<64 {
            guard let step = current else { return false }
            if step == ancestor { return true }
            current = folderSnapshot(step)?.parentID
        }
        return false
    }

    private func folderSnapshot(_ id: FolderID) -> FolderSnapshot? {
        allFolders.first { $0.folder.id == id }?.folder
    }

    private func snapshot(of id: ObjectID) -> ObjectSnapshot? {
        visibleObjects.first { $0.id == id }
    }

    private func snapshots(of ids: [ObjectID]) -> [ObjectSnapshot] {
        ids.compactMap { snapshot(of: $0) }
    }
}

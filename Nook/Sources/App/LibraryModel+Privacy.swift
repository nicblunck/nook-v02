import Foundation
import NookLibrary

/// Hidden and Locked, from the interface's side.
///
/// Nothing here decides what may be seen — the privacy broker does that, below
/// every consumer. What the app does is narrower and entirely explicit: ask the
/// device owner, and on a yes raise the `AccessContext` every read is made
/// under. That is why hiding and unlocking live together in one file: they are
/// the same act performed against different flags.
extension LibraryModel {

    // MARK: The hidden context

    /// Whether hidden content is currently being shown.
    var isShowingHiddenContent: Bool { accessContext.hiddenContextUnlocked }

    /// Brings hidden content into view for as long as the user stays in it.
    ///
    /// One authentication reveals everything hidden rather than one item at a
    /// time: hiding is about discovery, and a library where each hidden item
    /// had to be found before it could be revealed would be unusable.
    func showHiddenContent() async {
        guard !isShowingHiddenContent else { return }
        guard await authenticate(reason: "Show hidden items in your library.") else { return }
        accessContext = accessContext.enteringHiddenContext()
        await refreshAll()
    }

    /// Puts everything back out of sight, and drops every lock authenticated
    /// along the way with it. Leaving is not a state change to be confirmed —
    /// it only ever takes access away.
    func hideHiddenContent() async {
        guard accessContext.hiddenContextUnlocked || !accessContext.unlockedEntities.isEmpty else { return }
        accessContext = .standard
        previewedObjectID = nil
        await retreatFromUnreachableScope()
        await refreshAll()
    }

    // MARK: Locks

    /// Authenticates against whatever imposes an item's lock — which may be an
    /// ancestor folder rather than the item itself, and releases that whole
    /// branch when it is.
    ///
    /// Returns true when the caller may go on to open the thing, including the
    /// case where it was never locked to begin with.
    @discardableResult
    func unlock(_ item: some PrivacyBearing, named name: String) async -> Bool {
        guard let source = item.lockedSource else { return true }
        guard !accessContext.unlockedEntities.contains(source.uuid) else { return true }
        guard await authenticate(reason: "Unlock “\(name)”.") else { return false }
        accessContext = accessContext.unlocking(source)
        await refreshAll()
        return true
    }

    /// Whether the location on screen is one the user has yet to authenticate.
    var lockedLocation: (reference: LibraryReference, name: String)? {
        switch scope {
        case .folder(let id), .folderTree(let id):
            guard let folder = breadcrumbs.last, folder.id == id, folder.visibility.isRedacted else { return nil }
            return (folder.reference, folder.name)
        case .collection(let id):
            guard let collection = collections.first(where: { $0.id == id }),
                  collection.visibility.isRedacted
            else { return nil }
            return (collection.reference, collection.name)
        default:
            return nil
        }
    }

    /// Opens the lock on the location currently being browsed.
    func unlockCurrentLocation() async {
        switch scope {
        case .folder(let id), .folderTree(let id):
            guard let folder = breadcrumbs.last, folder.id == id else { return }
            await unlock(folder, named: folder.name)
        case .collection(let id):
            guard let collection = collections.first(where: { $0.id == id }) else { return }
            await unlock(collection, named: collection.name)
        default:
            break
        }
    }

    // MARK: Setting privacy

    func setHidden(_ isHidden: Bool, for objects: [ObjectSnapshot]) async {
        let ids = objects.map(\.id)
        guard !ids.isEmpty else { return }
        guard await authenticate(reason: reason(isHidden ? "Hide" : "Unhide", count: ids.count)) else { return }
        // Hiding something while hidden content is not on screen takes it out
        // from under the selection, so the selection goes with it.
        await perform { try await self.library.service.setHidden(isHidden, forObjects: ids) }
    }

    func setLocked(_ isLocked: Bool, for objects: [ObjectSnapshot]) async {
        let ids = objects.map(\.id)
        guard !ids.isEmpty else { return }
        guard await authenticate(reason: reason(isLocked ? "Lock" : "Unlock", count: ids.count)) else { return }
        if isLocked, let previewed = previewedObjectID, ids.contains(previewed) { previewedObjectID = nil }
        await perform { try await self.library.service.setLocked(isLocked, forObjects: ids) }
    }

    func setHidden(_ isHidden: Bool, forFolder folder: FolderSnapshot) async {
        guard await authenticate(reason: "\(isHidden ? "Hide" : "Unhide") “\(folder.name)”.") else { return }
        if isHidden, !isShowingHiddenContent { await leave(.folder(folder.id)) }
        await perform { try await self.library.service.setHidden(isHidden, forFolder: folder.id) }
    }

    func setLocked(_ isLocked: Bool, forFolder folder: FolderSnapshot) async {
        guard await authenticate(reason: "\(isLocked ? "Lock" : "Unlock") “\(folder.name)”.") else { return }
        await perform { try await self.library.service.setLocked(isLocked, forFolder: folder.id) }
    }

    func setHidden(_ isHidden: Bool, forCollection collection: CollectionSnapshot) async {
        guard await authenticate(reason: "\(isHidden ? "Hide" : "Unhide") “\(collection.name)”.") else { return }
        if isHidden, !isShowingHiddenContent { await leave(.collection(collection.id)) }
        await perform { try await self.library.service.setHidden(isHidden, forCollection: collection.id) }
    }

    func setLocked(_ isLocked: Bool, forCollection collection: CollectionSnapshot) async {
        guard await authenticate(reason: "\(isLocked ? "Lock" : "Unlock") “\(collection.name)”.") else { return }
        await perform { try await self.library.service.setLocked(isLocked, forCollection: collection.id) }
    }

    // MARK: Internals

    private func reason(_ verb: String, count: Int) -> String {
        count == 1 ? "\(verb) this item." : "\(verb) \(count) items."
    }

    /// Asks the device owner. A cancelled prompt is an answer, not a fault, so
    /// only a real failure is worth an alert.
    private func authenticate(reason: String) async -> Bool {
        switch await authenticator.authenticate(reason: reason) {
        case .succeeded:
            return true
        case .cancelled:
            return false
        case .failed(let message):
            alert = LibraryAlert(title: "Couldn't authenticate", message: message)
            return false
        }
    }

    /// Steps out of a location that is about to become unreachable, so the
    /// canvas is never left pointing at somewhere the user may no longer see.
    private func leave(_ location: LibraryScope) async {
        guard scope == location else { return }
        scope = .inbox
    }

    private func retreatFromUnreachableScope() async {
        switch scope {
        case .folder(let id), .folderTree(let id):
            if await library.service.folder(id, in: accessContext) == nil { scope = .inbox }
        case .collection(let id):
            if await library.service.collection(id, in: accessContext) == nil { scope = .inbox }
        default:
            break
        }
    }
}

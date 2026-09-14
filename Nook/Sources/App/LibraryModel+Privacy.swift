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

    // MARK: Hidden

    /// Whether Hidden is currently open.
    var isShowingHiddenContent: Bool { accessContext.hiddenContextUnlocked }

    /// Opens Hidden.
    ///
    /// It is a place rather than a filter: what is hidden lives there and is
    /// absent from every other view, so authenticating opens one door instead
    /// of turning the whole library transparent. Unhiding something puts it
    /// back in the folder it came from — or in the Inbox, if that folder is
    /// gone by the time it comes back.
    func openHidden() async {
        if !isShowingHiddenContent {
            guard await authenticate(reason: "Show your hidden items.") else { return }
            accessContext = accessContext.enteringHiddenContext()
            scheduleRehide()
        }
        navigate(to: .scope(.hidden))
        await refreshAll()
    }

    /// Closes Hidden once the destination the canvas is pointed at no longer
    /// belongs to it — called on every navigation rather than only from a
    /// button, so leaving Hidden always closes the door behind it. Standing
    /// inside Hidden itself, or inside a folder hidden in its own right,
    /// keeps it open.
    ///
    /// Narrows access and nothing else: the navigation this runs inside of
    /// already refreshes the canvas for wherever it is heading next, and
    /// every read is narrowed per scope regardless, so a second contents
    /// refresh here would only race the one already under way.
    func closeHidden() async {
        guard isShowingHiddenContent else { return }
        let destination: LibraryScope? = isShowingHome ? nil : scope
        if let destination, await library.service.revealsHiddenContent(destination) { return }
        hiddenRevealTask?.cancel()
        hiddenRevealTask = nil
        if previewedObject?.isHidden == true { previewedObjectID = nil }
        accessContext = accessContext.leavingHiddenContext()
        await refreshSidebar()
    }

    /// Filters hidden items out again without discarding authenticated locks.
    func rehideItems() async {
        guard isShowingHiddenContent else { return }
        hiddenRevealTask?.cancel()
        hiddenRevealTask = nil

        let previewWasHidden = previewedObject?.isHidden == true
        accessContext = accessContext.leavingHiddenContext()
        if previewWasHidden { previewedObjectID = nil }

        await refreshSidebar()
        if case .folder(let id) = scope,
           !allFolders.contains(where: { $0.folder.id == id }) {
            await leave(.folder(id))
        }
        await refreshContents()
    }

    func appDidLoseFocus() async {
        guard settings.rehidesWhenAppLosesFocus, isShowingHiddenContent else { return }
        await rehideItems()
    }

    /// Restarts the hidden-content deadline while the owner is actively using
    /// this window. Activity has no privacy side effects before authentication
    /// or when the user has chosen to keep hidden items revealed indefinitely.
    func appDidReceiveUserActivity() {
        guard isShowingHiddenContent,
              settings.hiddenRevealTimeout.duration != nil
        else { return }
        scheduleRehide()
    }

    private func scheduleRehide() {
        hiddenRevealTask?.cancel()
        guard let timeout = settings.hiddenRevealTimeout.duration else {
            hiddenRevealTask = nil
            return
        }
        let sleep = hiddenRevealSleep
        hiddenRevealTask = Task { [weak self, sleep] in
            try? await sleep(timeout)
            guard !Task.isCancelled, let self else { return }
            guard isShowingHiddenContent else { return }
            await rehideItems()
        }
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
        guard !isShowingHome else { return nil }
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
        // Hiding something while hidden content is not on screen takes it out
        // from under the selection, so the selection goes with it.
        await perform { try await self.library.service.setHidden(isHidden, forObjects: ids) }
    }

    /// The drag-and-drop surfaces already have stable ids, so they do not need
    /// to reconstruct snapshots just to apply the same privacy operation.
    func setHidden(_ isHidden: Bool, for ids: [ObjectID]) async {
        guard !ids.isEmpty else { return }
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
        await setHidden(isHidden, forFolder: folder.id)
    }

    /// The id-only entry point, for callers — a drop target among them — that
    /// only ever had an id to begin with: a folder reached by descending into
    /// Hidden never has a snapshot in the ordinary tree to hand over.
    func setHidden(_ isHidden: Bool, forFolder id: FolderID) async {
        if isHidden, !isShowingHiddenContent { await leave(.folder(id)) }
        await perform { try await self.library.service.setHidden(isHidden, forFolder: id) }
    }

    func setLocked(_ isLocked: Bool, forFolder folder: FolderSnapshot) async {
        guard await authenticate(reason: "\(isLocked ? "Lock" : "Unlock") “\(folder.name)”.") else { return }
        await perform { try await self.library.service.setLocked(isLocked, forFolder: folder.id) }
    }

    func setHidden(_ isHidden: Bool, forCollection collection: CollectionSnapshot) async {
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
}

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
    func openHidden(startingPageStack: Bool = false) async {
        if !isShowingHiddenContent {
            guard await authenticate(reason: "Show your hidden items.") else { return }
            accessContext = accessContext.enteringHiddenContext()
            scheduleRehide()
        }
        navigate(to: .scope(.hidden), startingPageStack: startingPageStack)
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
        if previewedObject?.isHidden == true { previewedObjectID = nil }
        accessContext = accessContext.leavingHiddenContext()
        cancelCloseTimerIfNothingIsOpen()
        await refreshSidebar()
    }

    /// Filters hidden items out again without discarding authenticated locks.
    func rehideItems() async {
        guard isShowingHiddenContent else { return }

        let previewWasHidden = previewedObject?.isHidden == true
        accessContext = accessContext.leavingHiddenContext()
        if previewWasHidden { previewedObjectID = nil }
        cancelCloseTimerIfNothingIsOpen()

        await refreshSidebar()
        if case .folder(let id) = scope,
           !allFolders.contains(where: { $0.folder.id == id }) {
            // This folder was only reachable through Hidden, so it vanishes
            // along with everything else in there. Landing back on Hidden
            // itself — rather than out in the ordinary library — keeps the
            // door shut in front of the user instead of stepping them past it.
            await leave(.folder(id), returningTo: .hidden)
        }
        await refreshContents()
    }

    // MARK: Closing on idle and focus loss

    /// Whether Hidden or any locked folder is open right now. Both follow the
    /// same idle timer and the same focus rule, so one question covers both.
    var isAnyProtectedPlaceOpen: Bool {
        isShowingHiddenContent || !accessContext.unlockedEntities.isEmpty
    }

    func appDidLoseFocus() async {
        guard settings.rehidesWhenAppLosesFocus, isAnyProtectedPlaceOpen else { return }
        await closeProtectedPlaces()
    }

    /// Restarts the close deadline while the owner is actively using this
    /// window. Activity has no privacy side effects before authentication or
    /// when the user has chosen to keep protected places open indefinitely.
    func appDidReceiveUserActivity() {
        guard isAnyProtectedPlaceOpen,
              settings.hiddenRevealTimeout.duration != nil
        else { return }
        scheduleRehide()
    }

    /// Closes Hidden and every open locked folder together — what the idle
    /// timer and focus loss do.
    func closeProtectedPlaces() async {
        // Hidden's own close refreshes the canvas, so the folders closing
        // first leave that to it rather than refreshing twice.
        await relockFolders(refreshing: !isShowingHiddenContent)
        await rehideItems()
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
            guard isAnyProtectedPlaceOpen else { return }
            await closeProtectedPlaces()
        }
    }

    /// Drops the pending deadline once neither Hidden nor any locked folder is
    /// open, so a timer never outlives what it was set for.
    private func cancelCloseTimerIfNothingIsOpen() {
        guard !isAnyProtectedPlaceOpen else { return }
        hiddenRevealTask?.cancel()
        hiddenRevealTask = nil
    }

    // MARK: Locks

    /// Authenticates against a locked folder and releases it — and everything
    /// beneath it — for as long as the browsed location stays inside its
    /// subtree. Leaving that subtree re-locks it; see `closeLockedFolders()`.
    ///
    /// Returns true when the caller may go on to open the folder, including
    /// the case where it was never locked to begin with.
    ///
    /// `refreshing` defaults to true for a caller that is already sitting at
    /// the location being unlocked — the refresh is what makes the now-full
    /// contents actually appear. A caller about to navigate there, such as
    /// `openFolder`, passes false: refreshing here would run while `scope`
    /// still points at wherever the canvas was a moment ago, so
    /// `closeLockedFolders()` would see the new unlock as not covering the
    /// current place and revoke it immediately, before the navigation this
    /// unlock exists for ever lands. The navigation that follows triggers its
    /// own refresh once `scope` actually is the unlocked folder.
    @discardableResult
    func unlock(_ item: some PrivacyBearing, named name: String, refreshing: Bool = true) async -> Bool {
        guard let source = item.lockedSource else { return true }
        guard !accessContext.unlockedEntities.contains(source.uuid) else { return true }
        guard await authenticate(reason: "Open “\(name)”.") else { return false }
        accessContext = accessContext.unlocking(source)
        scheduleRehide()
        if refreshing { await refreshAll() }
        return true
    }

    /// Whether the location on screen is one the user has yet to authenticate.
    /// Only folders can be locked doors; collections never are.
    var lockedLocation: (reference: LibraryReference, name: String)? {
        guard !isShowingHome else { return nil }
        switch scope {
        case .folder(let id), .folderTree(let id):
            guard let folder = breadcrumbs.last, folder.id == id, folder.visibility.isRedacted else { return nil }
            return (folder.reference, folder.name)
        default:
            return nil
        }
    }

    /// Opens a folder — authenticating first when it is itself a locked door,
    /// so the canvas lands straight on its contents rather than showing the
    /// door and waiting for a separate Unlock click. Declining authentication
    /// opens nothing; the browsed location stays exactly where it was.
    func openFolder(_ id: FolderID, startingPageStack: Bool = false) async {
        if let folder = await library.service.folder(id, in: accessContext), folder.visibility.isRedacted {
            guard await unlock(folder, named: folder.name, refreshing: false) else { return }
            // The sidebar shows this folder's own lock badge as open the
            // instant it's authenticated, rather than waiting on whatever
            // the navigation below happens to refresh.
            await refreshSidebar()
        }
        navigate(to: .scope(.folder(id)), startingPageStack: startingPageStack)
    }

    /// Opens the lock on the folder currently being browsed.
    func unlockCurrentLocation() async {
        switch scope {
        case .folder(let id), .folderTree(let id):
            guard let folder = breadcrumbs.last, folder.id == id else { return }
            await unlock(folder, named: folder.name)
        default:
            break
        }
    }

    /// Re-locks any folder whose subtree the browsed location has left —
    /// called on every navigation, the same choke point `closeHidden()` uses,
    /// so leaving a locked folder always closes the door behind it. Standing
    /// inside it, or inside a folder nested beneath it, keeps it open.
    func closeLockedFolders() async {
        guard !accessContext.unlockedEntities.isEmpty else { return }
        let destination: LibraryScope? = isShowingHome ? nil : scope
        let stillOpen = await library.service.unlockedFoldersInScope(destination, among: accessContext.unlockedEntities)
        guard stillOpen != accessContext.unlockedEntities else { return }
        accessContext.unlockedEntities = stillOpen
        if let previewed = previewedObject, previewed.isLocked,
           let source = previewed.lockedSource, !stillOpen.contains(source.uuid) {
            previewedObjectID = nil
        }
        cancelCloseTimerIfNothingIsOpen()
        // A folder that just re-locked shows that in the sidebar right away,
        // the same way `closeHidden()` refreshes it on the way out.
        await refreshSidebar()
    }

    /// Closes every open locked folder, wherever the canvas stands — what
    /// Lock Now, the idle timer and focus loss do.
    ///
    /// A lock is a gate, so whoever is standing somewhere behind it when it
    /// closes ends up back in front of the gate: the locked folder itself,
    /// showing its locked screen, rather than a subfolder that has vanished.
    func relockFolders(refreshing: Bool = true) async {
        guard !accessContext.unlockedEntities.isEmpty else { return }
        var gate: FolderID?
        switch scope {
        case .folder(let id), .folderTree(let id):
            if !isShowingHome, let here = breadcrumbs.last, here.id == id,
               case .folder(let source)? = here.lockedSource, source != id {
                gate = source
            }
        default:
            break
        }

        accessContext.unlockedEntities = []
        if previewedObject?.isLocked == true { previewedObjectID = nil }
        if let gate { scope = .folder(gate) }
        cancelCloseTimerIfNothingIsOpen()
        guard refreshing else { return }
        await refreshSidebar()
        await refreshContents()
    }

    // MARK: Setting privacy

    func setHidden(_ isHidden: Bool, for objects: [ObjectSnapshot]) async {
        let ids = objects.map(\.id)
        guard !ids.isEmpty else { return }
        // Hiding something while hidden content is not on screen takes it out
        // from under the selection, so the selection goes with it.
        let message: LocalizedStringResource
        if ids.count == 1 {
            message = isHidden ? "Hidden item" : "Unhidden item"
        } else {
            message = isHidden ? "Hidden \(ids.count) items" : "Unhidden \(ids.count) items"
        }
        await perform(
            successToast: message,
            systemImage: isHidden ? "eye.slash.fill" : "eye.fill",
            tint: isHidden ? .orange : .green
        ) {
            try await self.library.service.setHidden(isHidden, forObjects: ids)
        }
    }

    /// The drag-and-drop surfaces already have stable ids, so they do not need
    /// to reconstruct snapshots just to apply the same privacy operation.
    func setHidden(_ isHidden: Bool, for ids: [ObjectID]) async {
        guard !ids.isEmpty else { return }
        let message: LocalizedStringResource
        if ids.count == 1 {
            message = isHidden ? "Hidden item" : "Unhidden item"
        } else {
            message = isHidden ? "Hidden \(ids.count) items" : "Unhidden \(ids.count) items"
        }
        await perform(
            successToast: message,
            systemImage: isHidden ? "eye.slash.fill" : "eye.fill",
            tint: isHidden ? .orange : .green
        ) {
            try await self.library.service.setHidden(isHidden, forObjects: ids)
        }
    }

    func setHidden(_ isHidden: Bool, forFolder folder: FolderSnapshot) async {
        await setHidden(isHidden, forFolder: folder.id)
    }

    /// The id-only entry point, for callers — a drop target among them — that
    /// only ever had an id to begin with: a folder reached by descending into
    /// Hidden never has a snapshot in the ordinary tree to hand over.
    func setHidden(_ isHidden: Bool, forFolder id: FolderID) async {
        if isHidden, !isShowingHiddenContent { await leave(.folder(id)) }
        await perform(
            successToast: isHidden ? "Hidden folder" : "Unhidden folder",
            systemImage: isHidden ? "eye.slash.fill" : "eye.fill",
            tint: isHidden ? .orange : .green
        ) {
            try await self.library.service.setHidden(isHidden, forFolder: id)
        }
    }

    func setLocked(_ isLocked: Bool, forFolder folder: FolderSnapshot) async {
        let reason = isLocked ? "Lock “\(folder.name)”." : "Remove the lock from “\(folder.name)”."
        guard await authenticate(reason: reason) else { return }
        await perform(
            successToast: isLocked ? "Locked folder" : "Lock removed",
            systemImage: isLocked ? "lock.fill" : "lock.open.fill",
            tint: isLocked ? .orange : .green
        ) {
            try await self.library.service.setLocked(isLocked, forFolder: folder.id)
        }
    }

    func setHidden(_ isHidden: Bool, forCollection collection: CollectionSnapshot) async {
        if isHidden, !isShowingHiddenContent { await leave(.collection(collection.id)) }
        await perform(
            successToast: isHidden ? "Hidden collection" : "Unhidden collection",
            systemImage: isHidden ? "eye.slash.fill" : "eye.fill",
            tint: isHidden ? .orange : .green
        ) {
            try await self.library.service.setHidden(isHidden, forCollection: collection.id)
        }
    }

    // MARK: Internals

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
    private func leave(_ location: LibraryScope, returningTo fallback: LibraryScope = .inbox) async {
        guard scope == location else { return }
        scope = fallback
    }
}

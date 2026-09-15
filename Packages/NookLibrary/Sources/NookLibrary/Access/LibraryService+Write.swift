import Foundation
import SwiftData

public extension LibraryService {

    // MARK: Folders

    @discardableResult
    func createFolder(
        named name: String,
        in parent: FolderID? = nil,
        appearance: EntityAppearance = .system
    ) throws -> FolderSnapshot {
        let parentFolder = parent.flatMap { folder(withIdentifier: $0.uuid) }
        if let parent, parentFolder == nil { throw LibraryError.folderNotFound(parent) }

        let created = Folder(name: sanitized(name, fallback: "Untitled Folder"), parent: parentFolder)
        created.colorHex = appearance.colorHex
        created.symbolName = appearance.symbolName
        created.emoji = appearance.emoji
        context.insert(created)
        try didMutate()
        return snapshot(created, access: .standard)!
    }

    func renameFolder(_ id: FolderID, to name: String) throws {
        guard let folder = folder(withIdentifier: id.uuid) else { throw LibraryError.folderNotFound(id) }
        folder.name = sanitized(name, fallback: folder.name)
        try didMutate()
    }

    func setAppearance(_ appearance: EntityAppearance, forFolder id: FolderID) throws {
        guard let folder = folder(withIdentifier: id.uuid) else { throw LibraryError.folderNotFound(id) }
        folder.colorHex = appearance.colorHex
        folder.symbolName = appearance.symbolName
        folder.emoji = appearance.emoji
        try didMutate()
    }

    func updateFolder(_ id: FolderID, name: String, appearance: EntityAppearance) throws {
        guard let folder = folder(withIdentifier: id.uuid) else { throw LibraryError.folderNotFound(id) }
        folder.name = sanitized(name, fallback: folder.name)
        folder.colorHex = appearance.colorHex
        folder.symbolName = appearance.symbolName
        folder.emoji = appearance.emoji
        try didMutate()
    }

    /// Moves a folder, refusing a move into its own subtree — which would
    /// detach that branch from the root entirely.
    func moveFolder(_ id: FolderID, to newParent: FolderID?) throws {
        guard let moved = folder(withIdentifier: id.uuid) else { throw LibraryError.folderNotFound(id) }

        guard let newParent else {
            moved.parent = nil
            try didMutate()
            return
        }
        guard let destination = folder(withIdentifier: newParent.uuid) else {
            throw LibraryError.folderNotFound(newParent)
        }
        guard !destination.isDescendant(of: moved) else {
            throw LibraryError.invalidFolderMove(reason: "A folder can't be moved inside itself.")
        }
        moved.parent = destination
        try didMutate()
    }

    /// Deletes a folder and its subfolders. Contained objects are sent to
    /// Recently Deleted rather than removed, so the deletion stays reversible
    /// for the retention window.
    ///
    /// Nothing explicitly hidden is ever contained here: hiding an object
    /// detaches it from its folder the moment it happens, so a folder never
    /// holds anything the user could not currently see when they chose to
    /// delete it.
    func deleteFolder(_ id: FolderID) throws {
        guard let target = folder(withIdentifier: id.uuid) else { throw LibraryError.folderNotFound(id) }

        var queue: [Folder] = [target]
        var seen: Set<UUID> = []
        let now = Date.now
        while let current = queue.popLast() {
            guard seen.insert(current.identifier).inserted else { continue }
            for object in current.containedObjects where object.deletedAt == nil {
                object.deletedAt = now
                object.folder = nil
            }
            queue.append(contentsOf: current.childFolders)
        }

        context.delete(target)
        try didMutate()
    }

    func setPrivacy(_ flags: PrivacyFlags, forFolder id: FolderID) throws {
        guard let target = folder(withIdentifier: id.uuid) else { throw LibraryError.folderNotFound(id) }
        target.isHidden = flags.isHidden
        target.isLocked = flags.isLocked
        if flags.isHidden { target.parent = nil }
        try didMutate()
    }

    /// Hidden and Locked are also settable one at a time, which is how the
    /// interface sets them: hiding something says nothing about whether it is
    /// locked, and writing both at once would make a caller restate a flag it
    /// has no opinion about. Only the entity's own flag is ever written —
    /// what it inherits from an ancestor remains the ancestor's to lift.
    ///
    /// Hiding also detaches the folder from wherever it was — Hidden behaves
    /// like a folder itself, and what is put into it does not need to
    /// remember where it came from. A folder already hidden in its own right
    /// stays exactly where hiding put it; only newly hiding one moves it.
    func setHidden(_ isHidden: Bool, forFolder id: FolderID) throws {
        guard let target = folder(withIdentifier: id.uuid) else { throw LibraryError.folderNotFound(id) }
        target.isHidden = isHidden
        if isHidden { target.parent = nil }
        try didMutate()
    }

    func setLocked(_ isLocked: Bool, forFolder id: FolderID) throws {
        guard let target = folder(withIdentifier: id.uuid) else { throw LibraryError.folderNotFound(id) }
        target.isLocked = isLocked
        try didMutate()
    }

    // MARK: Objects

    func moveObjects(_ ids: [ObjectID], to destination: FolderID?) throws {
        let destinationFolder: Folder?
        if let destination {
            guard let resolved = folder(withIdentifier: destination.uuid) else {
                throw LibraryError.folderNotFound(destination)
            }
            destinationFolder = resolved
        } else {
            destinationFolder = nil
        }

        for object in objects(withIdentifiers: ids.map(\.uuid)) {
            object.folder = destinationFolder
        }
        try didMutate()
    }

    func setFavorite(_ isFavorite: Bool, for ids: [ObjectID]) throws {
        for object in objects(withIdentifiers: ids.map(\.uuid)) {
            object.isFavorite = isFavorite
        }
        try didMutate()
    }

    func updateObject(_ id: ObjectID, title: String? = nil, notes: String? = nil) throws {
        guard let object = object(withIdentifier: id.uuid) else { throw LibraryError.objectNotFound(id) }
        if let title { object.title = sanitized(title, fallback: object.title) }
        if let notes { object.notes = notes }
        try didMutate()
    }

    /// Objects have no lock of their own — only `isHidden` is settable here.
    /// `flags.isLocked` is ignored; whatever an object shows for lock comes
    /// entirely from its folder ancestry.
    func setPrivacy(_ flags: PrivacyFlags, forObjects ids: [ObjectID]) throws {
        for object in objects(withIdentifiers: ids.map(\.uuid)) {
            object.isHidden = flags.isHidden
            if flags.isHidden { object.folder = nil }
        }
        try didMutate()
    }

    /// Hiding moves an object into Hidden rather than marking it in place: it
    /// no longer needs to remember which folder it came from, the way an
    /// object dropped into any other folder does not remember the one it left.
    /// Unhiding is the mirror of that — the object was detached, not filed
    /// anywhere in particular, so it surfaces in the Inbox like anything else
    /// without a folder.
    func setHidden(_ isHidden: Bool, forObjects ids: [ObjectID]) throws {
        for object in objects(withIdentifiers: ids.map(\.uuid)) {
            object.isHidden = isHidden
            if isHidden { object.folder = nil }
        }
        try didMutate()
    }

    // MARK: Deletion

    /// Sends objects to Recently Deleted. Their folder location is remembered
    /// nowhere, so a restore returns them to the Inbox.
    func delete(_ ids: [ObjectID]) throws {
        let now = Date.now
        for object in objects(withIdentifiers: ids.map(\.uuid)) where object.deletedAt == nil {
            object.deletedAt = now
        }
        try didMutate()
    }

    func restore(_ ids: [ObjectID]) throws {
        for object in objects(withIdentifiers: ids.map(\.uuid)) {
            object.deletedAt = nil
        }
        try didMutate()
    }

    func permanentlyDelete(_ ids: [ObjectID]) async throws {
        for object in objects(withIdentifiers: ids.map(\.uuid)) {
            context.delete(object)
        }
        try didMutate()
        try await collectOrphanedBlobs()
    }

    func emptyRecentlyDeleted() async throws {
        let descriptor = FetchDescriptor<LibraryObject>(
            predicate: #Predicate { $0.deletedAt != nil }
        )
        for object in (try? context.fetch(descriptor)) ?? [] {
            context.delete(object)
        }
        try didMutate()
        try await collectOrphanedBlobs()
    }

    /// Removes objects whose retention window has passed. Called at launch.
    func purgeExpiredDeletions(retention: TimeInterval = 30 * 24 * 60 * 60) async throws {
        let cutoff = Date.now.addingTimeInterval(-retention)
        let descriptor = FetchDescriptor<LibraryObject>(
            predicate: #Predicate { $0.deletedAt != nil }
        )
        let expired = ((try? context.fetch(descriptor)) ?? [])
            .filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        guard !expired.isEmpty else { return }
        for object in expired { context.delete(object) }
        try didMutate()
        try await collectOrphanedBlobs()
    }

    /// Reclaims stored bytes once nothing durable points at them — including
    /// objects still sitting in Recently Deleted, which can still be restored.
    func collectOrphanedBlobs() async throws {
        let descriptor = FetchDescriptor<Blob>()
        let blobs = (try? context.fetch(descriptor)) ?? []
        var evicted: [BlobDescriptor] = []

        for blob in blobs where blob.isEligibleForCollection {
            if let descriptor = blob.descriptor { evicted.append(descriptor) }
            context.delete(blob)
        }
        guard !evicted.isEmpty else { return }
        try didMutate()

        for descriptor in evicted {
            try? await blobStore.evict(descriptor)
        }
    }

    // MARK: Tags

    /// Finds or creates a tag by name. Names are matched case-insensitively so
    /// the library does not accumulate near-duplicate tags.
    @discardableResult
    func tag(named name: String) throws -> TagSnapshot {
        let resolved = try resolveTag(named: name)
        try didMutate()
        return snapshot(resolved, access: .standard)
    }

    /// Creates a standalone tag, or resolves an existing tag with the same
    /// normalized name, and applies the appearance staged in the editor.
    @discardableResult
    func createTag(named name: String, appearance: EntityAppearance = .system) throws -> TagSnapshot {
        let resolved = try resolveTag(named: sanitized(name, fallback: "Untitled Tag"))
        resolved.colorHex = appearance.colorHex
        resolved.symbolName = appearance.symbolName
        resolved.emoji = appearance.emoji
        try didMutate()
        return snapshot(resolved, access: .standard)
    }

    func addTag(named name: String, to ids: [ObjectID]) throws {
        let resolved = try resolveTag(named: name)
        for object in objects(withIdentifiers: ids.map(\.uuid)) {
            var current = object.tags ?? []
            guard !current.contains(where: { $0.identifier == resolved.identifier }) else { continue }
            current.append(resolved)
            object.tags = current
        }
        try didMutate()
    }

    func removeTag(_ id: TagID, from ids: [ObjectID]) throws {
        guard let target = tag(withIdentifier: id.uuid) else { throw LibraryError.tagNotFound(id) }
        for object in objects(withIdentifiers: ids.map(\.uuid)) {
            object.tags = (object.tags ?? []).filter { $0.identifier != target.identifier }
        }
        try didMutate()
    }

    func renameTag(_ id: TagID, to name: String) throws {
        guard let target = tag(withIdentifier: id.uuid) else { throw LibraryError.tagNotFound(id) }
        target.name = sanitized(name, fallback: target.name)
        try didMutate()
    }

    func setAppearance(_ appearance: EntityAppearance, forTag id: TagID) throws {
        guard let target = tag(withIdentifier: id.uuid) else { throw LibraryError.tagNotFound(id) }
        target.colorHex = appearance.colorHex
        target.symbolName = appearance.symbolName
        target.emoji = appearance.emoji
        try didMutate()
    }

    func updateTag(_ id: TagID, name: String, appearance: EntityAppearance) throws {
        guard let target = tag(withIdentifier: id.uuid) else { throw LibraryError.tagNotFound(id) }
        target.name = sanitized(name, fallback: target.name)
        target.colorHex = appearance.colorHex
        target.symbolName = appearance.symbolName
        target.emoji = appearance.emoji
        try didMutate()
    }

    func deleteTag(_ id: TagID) throws {
        guard let target = tag(withIdentifier: id.uuid) else { throw LibraryError.tagNotFound(id) }
        context.delete(target)
        try didMutate()
    }

    // MARK: Collections

    @discardableResult
    func createCollection(
        named name: String,
        appearance: EntityAppearance = .system
    ) throws -> CollectionSnapshot {
        let created = LibraryCollection(name: sanitized(name, fallback: "Untitled Collection"))
        created.colorHex = appearance.colorHex
        created.symbolName = appearance.symbolName
        created.emoji = appearance.emoji
        context.insert(created)
        try didMutate()
        return snapshot(created, access: .standard)!
    }

    func renameCollection(_ id: CollectionID, to name: String) throws {
        guard let target = collection(withIdentifier: id.uuid) else {
            throw LibraryError.collectionNotFound(id)
        }
        target.name = sanitized(name, fallback: target.name)
        try didMutate()
    }

    func deleteCollection(_ id: CollectionID) throws {
        guard let target = collection(withIdentifier: id.uuid) else {
            throw LibraryError.collectionNotFound(id)
        }
        // Cascades to the membership records only. The objects themselves are
        // untouched: a collection never owned them.
        context.delete(target)
        try didMutate()
    }

    /// Adds objects to the end of a collection's manual order, skipping any
    /// that are already members.
    func addObjects(_ ids: [ObjectID], toCollection id: CollectionID) throws {
        guard let target = collection(withIdentifier: id.uuid) else {
            throw LibraryError.collectionNotFound(id)
        }
        var nextIndex = (target.orderedMemberships.last?.sortIndex ?? -1) + 1
        let existing = Set(target.orderedMemberships.compactMap { $0.object?.identifier })

        for object in objects(withIdentifiers: ids.map(\.uuid)) where !existing.contains(object.identifier) {
            let membership = CollectionMembership(collection: target, object: object, sortIndex: nextIndex)
            context.insert(membership)
            nextIndex += 1
        }
        try didMutate()
    }

    /// Removes membership only. Visibly distinct from deleting the object,
    /// which stays exactly where it is in the folder hierarchy.
    func removeObjects(_ ids: [ObjectID], fromCollection id: CollectionID) throws {
        guard let target = collection(withIdentifier: id.uuid) else {
            throw LibraryError.collectionNotFound(id)
        }
        let targets = Set(ids.map(\.uuid))
        for membership in target.orderedMemberships {
            if let objectID = membership.object?.identifier, targets.contains(objectID) {
                context.delete(membership)
            }
        }
        try didMutate()
    }

    /// Collection privacy protects this surface only. The member objects keep
    /// whatever privacy their folder ancestry gives them. Collections have no
    /// lock of their own; `flags.isLocked` is ignored.
    func setPrivacy(_ flags: PrivacyFlags, forCollection id: CollectionID) throws {
        guard let target = collection(withIdentifier: id.uuid) else {
            throw LibraryError.collectionNotFound(id)
        }
        target.isHidden = flags.isHidden
        try didMutate()
    }

    func setHidden(_ isHidden: Bool, forCollection id: CollectionID) throws {
        guard let target = collection(withIdentifier: id.uuid) else {
            throw LibraryError.collectionNotFound(id)
        }
        target.isHidden = isHidden
        try didMutate()
    }

    func setAppearance(_ appearance: EntityAppearance, forCollection id: CollectionID) throws {
        guard let target = collection(withIdentifier: id.uuid) else {
            throw LibraryError.collectionNotFound(id)
        }
        target.colorHex = appearance.colorHex
        target.symbolName = appearance.symbolName
        target.emoji = appearance.emoji
        try didMutate()
    }

    func updateCollection(_ id: CollectionID, name: String, appearance: EntityAppearance) throws {
        guard let target = collection(withIdentifier: id.uuid) else {
            throw LibraryError.collectionNotFound(id)
        }
        target.name = sanitized(name, fallback: target.name)
        target.colorHex = appearance.colorHex
        target.symbolName = appearance.symbolName
        target.emoji = appearance.emoji
        try didMutate()
    }
}

// MARK: - Internals

extension LibraryService {
    func resolveTag(named name: String) throws -> Tag {
        let normalized = Tag.normalize(name)
        let existing = ((try? context.fetch(FetchDescriptor<Tag>())) ?? [])
            .first { $0.normalizedName == normalized }
        if let existing { return existing }

        let created = Tag(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(created)
        return created
    }

    func sanitized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

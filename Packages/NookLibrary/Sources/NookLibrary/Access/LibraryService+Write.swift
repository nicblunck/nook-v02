import Foundation
import SwiftData

public extension LibraryService {

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String, in parent: FolderID? = nil) throws -> FolderSnapshot {
        let parentFolder = parent.flatMap { folder(withIdentifier: $0.uuid) }
        if let parent, parentFolder == nil { throw LibraryError.folderNotFound(parent) }

        let created = Folder(name: sanitized(name, fallback: "Untitled Folder"), parent: parentFolder)
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

    func setPrivacy(_ flags: PrivacyFlags, forObjects ids: [ObjectID]) throws {
        for object in objects(withIdentifiers: ids.map(\.uuid)) {
            object.isHidden = flags.isHidden
            object.isLocked = flags.isLocked
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

    func deleteTag(_ id: TagID) throws {
        guard let target = tag(withIdentifier: id.uuid) else { throw LibraryError.tagNotFound(id) }
        context.delete(target)
        try didMutate()
    }

    // MARK: Collections

    @discardableResult
    func createCollection(named name: String) throws -> CollectionSnapshot {
        let created = LibraryCollection(name: sanitized(name, fallback: "Untitled Collection"))
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

    /// Rewrites a collection's manual order to the given sequence. Objects not
    /// listed keep their relative order after the ones that are.
    func reorderCollection(_ id: CollectionID, objectOrder: [ObjectID]) throws {
        guard let target = collection(withIdentifier: id.uuid) else {
            throw LibraryError.collectionNotFound(id)
        }
        let position = Dictionary(uniqueKeysWithValues: objectOrder.enumerated().map { ($1.uuid, $0) })
        let memberships = target.orderedMemberships
        let reordered = memberships.enumerated().sorted { left, right in
            let leftKey = left.element.object.flatMap { position[$0.identifier] } ?? (objectOrder.count + left.offset)
            let rightKey = right.element.object.flatMap { position[$0.identifier] } ?? (objectOrder.count + right.offset)
            return leftKey < rightKey
        }
        for (index, entry) in reordered.enumerated() {
            entry.element.sortIndex = index
        }
        try didMutate()
    }

    /// Collection privacy protects this surface only. The member objects keep
    /// whatever privacy their folder ancestry gives them.
    func setPrivacy(_ flags: PrivacyFlags, forCollection id: CollectionID) throws {
        guard let target = collection(withIdentifier: id.uuid) else {
            throw LibraryError.collectionNotFound(id)
        }
        target.isHidden = flags.isHidden
        target.isLocked = flags.isLocked
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

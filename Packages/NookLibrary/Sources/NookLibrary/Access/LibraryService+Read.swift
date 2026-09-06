import Foundation
import SwiftData

public extension LibraryService {

    // MARK: Navigation

    /// The sidebar's tree. Hidden folders are never part of it, even in an
    /// authenticated session: they live in Hidden, and are reached by opening
    /// that place rather than by the library's structure leading to them.
    func rootFolders(in access: AccessContext = .standard) -> [FolderSnapshot] {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.parent == nil }
        )
        let folders = (try? context.fetch(descriptor)) ?? []
        return folderSnapshots(folders, access: access.leavingHiddenContext())
    }

    func subfolders(of parent: FolderID, in access: AccessContext = .standard) -> [FolderSnapshot] {
        guard let folder = folder(withIdentifier: parent.uuid) else { return [] }
        return folderSnapshots(folder.childFolders, access: self.access(access, reading: .folder(parent)))
    }

    /// What Hidden holds at its top level: the folders and objects hidden in
    /// their own right. Anything nested under one of them is reached by opening
    /// it, exactly as it would be anywhere else in the library.
    func hiddenFolders(in access: AccessContext = .standard) -> [FolderSnapshot] {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { $0.isHidden }
        )
        let folders = (try? context.fetch(descriptor)) ?? []
        return folderSnapshots(folders.filter { !hasHiddenAncestor($0.parent) }, access: access)
    }

    func folder(_ id: FolderID, in access: AccessContext = .standard) -> FolderSnapshot? {
        guard let folder = folder(withIdentifier: id.uuid) else { return nil }
        return snapshot(folder, access: access)
    }

    /// Breadcrumb path from the root down to and including this folder.
    func folderPath(to id: FolderID, in access: AccessContext = .standard) -> [FolderSnapshot] {
        guard let folder = folder(withIdentifier: id.uuid) else { return [] }
        let chain = (folder.ancestors.reversed() + [folder])
        return chain.compactMap { snapshot($0, access: access) }
    }

    func collections(in access: AccessContext = .standard) -> [CollectionSnapshot] {
        let descriptor = FetchDescriptor<LibraryCollection>()
        let collections = (try? context.fetch(descriptor)) ?? []
        return collections
            .compactMap { snapshot($0, access: access) }
            .sorted { ($0.name.localizedStandardCompare($1.name)) == .orderedAscending }
    }

    func collection(_ id: CollectionID, in access: AccessContext = .standard) -> CollectionSnapshot? {
        guard let collection = collection(withIdentifier: id.uuid) else { return nil }
        return snapshot(collection, access: access)
    }

    func tags(in access: AccessContext = .standard) -> [TagSnapshot] {
        let descriptor = FetchDescriptor<Tag>()
        let tags = (try? context.fetch(descriptor)) ?? []
        return tags
            .map { snapshot($0, access: access) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func tag(_ id: TagID, in access: AccessContext = .standard) -> TagSnapshot? {
        guard let tag = tag(withIdentifier: id.uuid) else { return nil }
        return snapshot(tag, access: access)
    }

    // MARK: Objects

    func object(_ id: ObjectID, in access: AccessContext = .standard) -> ObjectSnapshot? {
        guard let object = object(withIdentifier: id.uuid) else { return nil }
        return snapshot(object, access: access)
    }

    /// The single query entry point. Browsing, scoped search and global search
    /// all arrive here, so they cannot diverge in what they return or hide.
    func objects(matching query: ObjectQuery, in access: AccessContext = .standard) -> [ObjectSnapshot] {
        let access = self.access(access, reading: query.scope)
        guard allowsReadingContents(of: query.scope, in: access) else { return [] }
        var candidates = candidateObjects(for: query.scope)

        candidates = candidates.filter { object in
            if query.scope.showsDeleted {
                guard object.deletedAt != nil else { return false }
            } else {
                guard object.deletedAt == nil else { return false }
            }
            if query.favoritesOnly && !object.isFavorite { return false }
            if !query.kinds.isEmpty && !query.kinds.contains(object.kind) { return false }
            return true
        }

        if query.hasSearchText {
            let tokens = query.trimmedSearchText
                .split(whereSeparator: \.isWhitespace)
                .map { $0.lowercased() }
            candidates = candidates.filter { matches($0, tokens: tokens) }
        }

        var snapshots = candidates.compactMap { snapshot($0, access: access) }
        snapshots = sorted(snapshots, by: query.sort, scope: query.scope)

        if let limit = query.limit, snapshots.count > limit {
            snapshots = Array(snapshots.prefix(limit))
        }
        return snapshots
    }

    /// A folder's immediate contents — subfolders and objects together — for
    /// the browsing canvas.
    func contents(of scope: LibraryScope,
                  sort: ObjectSort = .default,
                  in access: AccessContext = .standard) -> LocationContents {
        let folders: [FolderSnapshot]
        switch scope {
        case .folder(let id), .folderTree(let id):
            folders = subfolders(of: id, in: access)
        case .hidden:
            folders = hiddenFolders(in: access)
        case .allObjects, .inbox:
            folders = []
        default:
            folders = []
        }

        let objects = objects(matching: ObjectQuery(scope: scope, sort: sort), in: access)
        return LocationContents(folders: folders, objects: objects)
    }

    /// Resolves a machine-readable reference back to the same entity.
    func resolve(_ reference: LibraryReference, in access: AccessContext = .standard) -> ResolvedReference? {
        switch reference {
        case .object(let id): object(id, in: access).map(ResolvedReference.object)
        case .folder(let id): folder(id, in: access).map(ResolvedReference.folder)
        case .collection(let id): collection(id, in: access).map(ResolvedReference.collection)
        case .tag(let id): tag(id, in: access).map(ResolvedReference.tag)
        }
    }

    // MARK: Content access

    /// A local file URL for an object's original, materialising it if the
    /// backing store can. Returns nil when the caller may not have the bytes —
    /// a lock is not something a caller can talk its way past here.
    func originalURL(for id: ObjectID, in access: AccessContext = .standard) async throws -> URL? {
        guard let object = object(withIdentifier: id.uuid) else {
            throw LibraryError.objectNotFound(id)
        }
        let privacy = PrivacyResolver.effectivePrivacy(of: object)
        guard broker.allowsContent(of: privacy, in: access) else {
            throw LibraryError.contentNotPermitted(.object(id))
        }
        guard let descriptor = object.blob?.descriptor else { return nil }
        return try await blobStore.materialize(descriptor)
    }

    // MARK: Counts

    /// How many objects a scope holds, for the sidebar's badges.
    ///
    /// Counting resolves privacy but stops there — building a snapshot walks
    /// an object's tags, collection memberships and blob, which is a great deal
    /// of work to then discard and only keep the tally of.
    func objectCount(in scope: LibraryScope, access: AccessContext = .standard) -> Int {
        let access = self.access(access, reading: scope)
        guard allowsReadingContents(of: scope, in: access) else { return 0 }
        return candidateObjects(for: scope).count { object in
            if scope.showsDeleted {
                guard object.deletedAt != nil else { return false }
            } else {
                guard object.deletedAt == nil else { return false }
            }
            let privacy = PrivacyResolver.effectivePrivacy(of: object)
            return broker.allowsDiscovery(of: privacy, in: access)
        }
    }
}

public enum ResolvedReference: Hashable, Sendable {
    case object(ObjectSnapshot)
    case folder(FolderSnapshot)
    case collection(CollectionSnapshot)
    case tag(TagSnapshot)
}

// MARK: - Internals

extension LibraryService {

    /// Collection protection applies to the collection surface. Its members
    /// remain visible elsewhere, but the protected surface cannot be used as a
    /// back door to enumerate them.
    func allowsReadingContents(of scope: LibraryScope, in access: AccessContext) -> Bool {
        guard case .collection(let id) = scope else { return true }
        guard let collection = collection(withIdentifier: id.uuid) else { return false }
        return broker.allowsContent(
            of: PrivacyResolver.surfacePrivacy(of: collection),
            in: access
        )
    }

    /// Whether a scope is somewhere hidden content belongs.
    ///
    /// Only Hidden itself, and the branches beneath a hidden folder, show it.
    /// Everywhere else reads as though nothing had been authenticated, so one
    /// answered prompt opens a place rather than the whole library.
    public func revealsHiddenContent(_ scope: LibraryScope) -> Bool {
        switch scope {
        case .hidden:
            return true
        case .folder(let id), .folderTree(let id):
            guard let folder = folder(withIdentifier: id.uuid) else { return false }
            return PrivacyResolver.effectivePrivacy(of: folder).isHidden
        case .collection(let id):
            // A hidden collection is a hidden place in its own right: being
            // inside one is being somewhere hidden things belong.
            guard let collection = collection(withIdentifier: id.uuid) else { return false }
            return PrivacyResolver.surfacePrivacy(of: collection).isHidden
        default:
            return false
        }
    }

    /// The access a scope is actually read under.
    func access(_ access: AccessContext, reading scope: LibraryScope) -> AccessContext {
        revealsHiddenContent(scope) ? access : access.leavingHiddenContext()
    }

    func hasHiddenAncestor(_ folder: Folder?) -> Bool {
        guard let folder else { return false }
        return PrivacyResolver.effectivePrivacy(of: folder).isHidden
    }

    func isDiscoverable(_ object: LibraryObject, in access: AccessContext) -> Bool {
        broker.allowsDiscovery(
            of: PrivacyResolver.effectivePrivacy(of: object),
            in: access
        )
    }

    /// Narrows to the rows a scope could possibly contain, before privacy,
    /// search and sort are applied.
    func candidateObjects(for scope: LibraryScope) -> [LibraryObject] {
        switch scope {
        case .allObjects, .recent, .recentlyDeleted:
            return (try? context.fetch(FetchDescriptor<LibraryObject>())) ?? []

        case .inbox:
            let descriptor = FetchDescriptor<LibraryObject>(
                predicate: #Predicate { $0.folder == nil }
            )
            return (try? context.fetch(descriptor)) ?? []

        case .favorites:
            let descriptor = FetchDescriptor<LibraryObject>(
                predicate: #Predicate { $0.isFavorite }
            )
            return (try? context.fetch(descriptor)) ?? []

        case .kind(let kind):
            let raw = kind.rawValue
            let descriptor = FetchDescriptor<LibraryObject>(
                predicate: #Predicate { $0.kindRaw == raw }
            )
            return (try? context.fetch(descriptor)) ?? []

        case .hidden:
            let descriptor = FetchDescriptor<LibraryObject>(
                predicate: #Predicate { $0.isHidden }
            )
            let objects = (try? context.fetch(descriptor)) ?? []
            // Something hidden inside a hidden folder is already reachable by
            // opening that folder here, so listing it at the top as well would
            // show the same thing twice.
            return objects.filter { !hasHiddenAncestor($0.folder) }

        case .folder(let id):
            return folder(withIdentifier: id.uuid)?.containedObjects ?? []

        case .folderTree(let id):
            guard let root = folder(withIdentifier: id.uuid) else { return [] }
            return descendantObjects(of: root)

        case .collection(let id):
            return collection(withIdentifier: id.uuid)?.orderedObjects ?? []

        case .tag(let id):
            return tag(withIdentifier: id.uuid)?.taggedObjects ?? []
        }
    }

    private func descendantObjects(of root: Folder) -> [LibraryObject] {
        var result: [LibraryObject] = []
        var queue: [Folder] = [root]
        var seen: Set<UUID> = []
        while let folder = queue.popLast() {
            guard seen.insert(folder.identifier).inserted else { continue }
            result.append(contentsOf: folder.containedObjects)
            queue.append(contentsOf: folder.childFolders)
        }
        return result
    }

    func matches(_ object: LibraryObject, tokens: [String]) -> Bool {
        var haystack = [
            object.title,
            object.notes,
            object.originalFilename ?? "",
            object.sourceURLString ?? "",
            object.sourceDomain ?? "",
            object.linkPageTitle ?? "",
            object.linkDescription ?? "",
            object.kind.displayName,
            object.folder?.name ?? ""
        ]
        haystack.append(contentsOf: object.tagList.map(\.name))
        haystack.append(contentsOf: object.memberships.compactMap { $0.collection?.name })

        let corpus = haystack.joined(separator: "\n").lowercased()
        return tokens.allSatisfy { corpus.contains($0) }
    }

    func sorted(_ snapshots: [ObjectSnapshot], by sort: ObjectSort, scope: LibraryScope) -> [ObjectSnapshot] {
        // Manual order is the order `candidateObjects` already produced for a
        // collection; anywhere else it has no meaning and falls back to recency.
        if sort.field == .manual {
            guard case .collection = scope else {
                return sorted(snapshots, by: .default, scope: scope)
            }
            return sort.ascending ? snapshots : snapshots.reversed()
        }

        let ordered = snapshots.sorted { lhs, rhs in
            switch sort.field {
            case .name:
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .dateAdded:
                if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
            case .dateCreated:
                let left = lhs.dateCreated ?? lhs.dateAdded
                let right = rhs.dateCreated ?? rhs.dateAdded
                if left != right { return left < right }
            case .kind:
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            case .size:
                let left = lhs.byteSize ?? 0
                let right = rhs.byteSize ?? 0
                if left != right { return left < right }
            case .manual:
                break
            }
            // Stable tie-break so equal keys do not shuffle between refreshes.
            return lhs.id.uuid.uuidString < rhs.id.uuid.uuidString
        }
        return sort.ascending ? ordered : ordered.reversed()
    }

    // MARK: Snapshot construction

    /// Builds a snapshot, or returns nil when the caller may not know the
    /// object exists at all. A redacted snapshot omits the protected fields
    /// rather than marking them, so no view can render what it was not given.
    func snapshot(_ object: LibraryObject, access: AccessContext) -> ObjectSnapshot? {
        let privacy = PrivacyResolver.effectivePrivacy(of: object)
        let visibility = broker.visibility(of: privacy, in: access)
        guard !visibility.isExcluded else { return nil }

        let full = visibility == .full
        let blobDescriptor = full ? object.blob?.descriptor : nil

        return ObjectSnapshot(
            id: object.id,
            kind: object.kind,
            title: full ? object.title : ObjectSnapshot.lockedPlaceholderTitle,
            visibility: visibility,
            notes: full ? object.notes : "",
            originalFilename: full ? object.originalFilename : nil,
            contentTypeIdentifier: full ? object.contentTypeIdentifier : nil,
            byteSize: full ? object.byteSize : nil,
            pixelWidth: full ? object.pixelWidth : nil,
            pixelHeight: full ? object.pixelHeight : nil,
            duration: full ? object.duration : nil,
            pageCount: full ? object.pageCount : nil,
            dateAdded: object.dateAdded,
            dateCreated: full ? object.dateCreated : nil,
            deletedAt: object.deletedAt,
            isFavorite: object.isFavorite,
            isHidden: privacy.isHidden,
            isLocked: privacy.isLocked,
            hiddenSource: privacy.hiddenSource,
            lockedSource: privacy.lockedSource,
            sourceURL: full ? object.sourceURL : nil,
            sourceDomain: full ? object.sourceDomain : nil,
            linkPageTitle: full ? object.linkPageTitle : nil,
            linkDescription: full ? object.linkDescription : nil,
            folderID: object.folder.map { FolderID($0.identifier) },
            folderName: full ? object.folder?.name : nil,
            tags: full ? object.tagList.map { snapshot($0, access: access) } : [],
            collectionIDs: full ? object.memberships.compactMap { $0.collection.map { CollectionID($0.identifier) } } : [],
            blob: blobDescriptor,
            blobAvailability: full ? object.blob?.availability : nil
        )
    }

    func snapshot(_ folder: Folder, access: AccessContext) -> FolderSnapshot? {
        let privacy = PrivacyResolver.effectivePrivacy(of: folder)
        let visibility = broker.visibility(of: privacy, in: access)
        guard !visibility.isExcluded else { return nil }

        // A locked folder keeps its name: it is the door the user has to find
        // in order to authenticate. What it contains stays withheld.
        let full = visibility == .full
        let discoverableChildren = folder.childFolders.count {
            broker.allowsDiscovery(
                of: PrivacyResolver.effectivePrivacy(of: $0),
                in: access
            )
        }
        let discoverableObjects = folder.containedObjects.count {
            $0.deletedAt == nil && isDiscoverable($0, in: access)
        }
        return FolderSnapshot(
            id: folder.id,
            name: folder.name,
            appearance: EntityAppearance(colorHex: folder.colorHex,
                                         symbolName: folder.symbolName,
                                         emoji: folder.emoji),
            parentID: folder.parent.map { FolderID($0.identifier) },
            subfolderCount: full ? discoverableChildren : 0,
            objectCount: full ? discoverableObjects : 0,
            isHidden: privacy.isHidden,
            isLocked: privacy.isLocked,
            hiddenSource: privacy.hiddenSource,
            lockedSource: privacy.lockedSource,
            visibility: visibility,
            dateAdded: folder.dateAdded
        )
    }

    func snapshot(_ collection: LibraryCollection, access: AccessContext) -> CollectionSnapshot? {
        let privacy = PrivacyResolver.surfacePrivacy(of: collection)
        let visibility = broker.visibility(of: privacy, in: access)
        guard !visibility.isExcluded else { return nil }

        let full = visibility == .full
        return CollectionSnapshot(
            id: collection.id,
            name: collection.name,
            appearance: EntityAppearance(colorHex: collection.colorHex,
                                         symbolName: collection.symbolName,
                                         emoji: collection.emoji),
            memberCount: full
                ? collection.orderedObjects.count { $0.deletedAt == nil && isDiscoverable($0, in: access) }
                : 0,
            isSmart: collection.isSmart,
            isHidden: privacy.isHidden,
            isLocked: privacy.isLocked,
            hiddenSource: privacy.hiddenSource,
            lockedSource: privacy.lockedSource,
            visibility: visibility,
            dateAdded: collection.dateAdded
        )
    }

    func snapshot(_ tag: Tag, access: AccessContext) -> TagSnapshot {
        TagSnapshot(
            id: tag.id,
            name: tag.name,
            appearance: EntityAppearance(colorHex: tag.colorHex,
                                         symbolName: tag.symbolName,
                                         emoji: tag.emoji),
            objectCount: tag.taggedObjects.count {
                $0.deletedAt == nil && isDiscoverable($0, in: access)
            }
        )
    }

    func folderSnapshots(_ folders: [Folder], access: AccessContext) -> [FolderSnapshot] {
        folders
            .compactMap { snapshot($0, access: access) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public extension ObjectSnapshot {
    /// Shown in place of a locked object's title.
    static let lockedPlaceholderTitle = "Locked Item"
}

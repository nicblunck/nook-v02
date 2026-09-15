import Foundation

/// The read-only capability surface every external consumer talks to.
///
/// One surface, whether the caller is an MCP adapter, an on-device model or a
/// hosted one — MCP is an adapter, not the architecture, so no protocol type
/// appears here. It is read-only by construction rather than by policy: there
/// are no write operations to call, which is what keeps the security and
/// recovery surface small while external access is young.
///
/// Every result comes back through `LibraryService`, so the privacy broker has
/// already run. Hidden content is not reachable; a locked item can appear in an
/// outline but yields no content. An instruction inside a prompt cannot change
/// either of those, because neither decision is made at this level.
public struct LibraryToolSurface: Sendable {
    private let service: LibraryService
    private let access: AccessContext

    /// Built with the caller's access context, which for every external
    /// consumer is `.standard` — the one that has authenticated nothing.
    public init(service: LibraryService, access: AccessContext = .standard) {
        self.service = service
        self.access = access
    }

    // MARK: Search

    public struct SearchRequest: Codable, Sendable {
        public var query: String
        public var kind: String?
        public var folderReference: String?
        public var collectionReference: String?
        public var tagReference: String?
        public var limit: Int

        public init(query: String,
                    kind: String? = nil,
                    folderReference: String? = nil,
                    collectionReference: String? = nil,
                    tagReference: String? = nil,
                    limit: Int = 20) {
            self.query = query
            self.kind = kind
            self.folderReference = folderReference
            self.collectionReference = collectionReference
            self.tagReference = tagReference
            self.limit = limit
        }
    }

    /// `search_objects`
    public func searchObjects(_ request: SearchRequest) async -> [ObjectDigest] {
        guard let scope = resolveScope(
            folder: request.folderReference,
            collection: request.collectionReference,
            tag: request.tagReference
        ) else { return [] }

        let kinds: Set<ObjectKind>
        if let requestedKind = request.kind {
            guard let kind = ObjectKind(rawValue: requestedKind) else { return [] }
            kinds = [kind]
        } else {
            kinds = []
        }

        return await service
            .objects(
                matching: ObjectQuery(scope: scope,
                                      searchText: request.query,
                                      kinds: kinds,
                                      limit: max(1, min(request.limit, 100))),
                in: access
            )
            .map(ObjectDigest.init)
    }

    /// `get_object`
    public func getObject(reference: String) async -> ObjectDigest? {
        guard case .object(let id)? = LibraryReference(reference) else { return nil }
        return await service.object(id, in: access).map(ObjectDigest.init)
    }

    /// `get_object_content`
    public func getObjectContent(reference: String) async -> ObjectContent? {
        guard case .object(let id)? = LibraryReference(reference),
              let snapshot = await service.object(id, in: access)
        else { return nil }

        // Only a folder that is itself the locked door ever resolves to
        // `.redacted` — an object buried behind one resolves to `.excluded`
        // and never reaches this point at all (`service.object` above
        // already returned nil for it). This function only ever looks up
        // objects, so in practice this branch cannot currently trigger; it
        // stays as a defensive backstop on the privacy boundary rather than
        // an assumption this surface silently depends on.
        guard !snapshot.visibility.isRedacted else {
            return ObjectContent(
                reference: snapshot.reference.description,
                kind: snapshot.kind.rawValue,
                title: snapshot.title,
                extractedText: nil,
                linkTitle: nil,
                linkDescription: nil,
                linkURL: nil,
                unavailableReason: "This item is locked."
            )
        }

        let text = try? await service.extractedText(for: id, in: access)
        let reason: String? = if text == nil && snapshot.kind != .link {
            "No text has been extracted from this item."
        } else {
            nil
        }

        return ObjectContent(
            reference: snapshot.reference.description,
            kind: snapshot.kind.rawValue,
            title: snapshot.title,
            extractedText: text,
            linkTitle: snapshot.linkPageTitle,
            linkDescription: snapshot.linkDescription,
            linkURL: snapshot.sourceURL?.absoluteString,
            unavailableReason: reason
        )
    }

    // MARK: Navigation

    /// `list_folder` — pass no reference for the library root.
    public func listFolder(reference: String? = nil) async -> (folders: [FolderDigest], objects: [ObjectDigest]) {
        guard let reference else {
            let folders = await service.rootFolders(in: access).map(FolderDigest.init)
            let objects = await service
                .objects(matching: ObjectQuery(scope: .inbox), in: access)
                .map(ObjectDigest.init)
            return (folders, objects)
        }
        guard case .folder(let id)? = LibraryReference(reference) else { return ([], []) }
        let folders = await service.subfolders(of: id, in: access).map(FolderDigest.init)
        let objects = await service
            .objects(matching: ObjectQuery(scope: .folder(id)), in: access)
            .map(ObjectDigest.init)
        return (folders, objects)
    }

    /// `list_collections`
    public func listCollections() async -> [CollectionDigest] {
        await service.collections(in: access).map(CollectionDigest.init)
    }

    /// `get_collection`
    public func getCollection(reference: String) async -> (collection: CollectionDigest, objects: [ObjectDigest])? {
        guard case .collection(let id)? = LibraryReference(reference),
              let snapshot = await service.collection(id, in: access)
        else { return nil }
        let objects = await service
            .objects(matching: ObjectQuery(scope: .collection(id)), in: access)
            .map(ObjectDigest.init)
        return (CollectionDigest(snapshot), objects)
    }

    /// `list_tags`
    public func listTags() async -> [TagDigest] {
        await service.tags(in: access).map(TagDigest.init)
    }

    /// `find_by_tag`
    public func findByTag(reference: String, limit: Int = 50) async -> [ObjectDigest] {
        guard case .tag(let id)? = LibraryReference(reference) else { return [] }
        return await service
            .objects(matching: ObjectQuery(scope: .tag(id), limit: limit), in: access)
            .map(ObjectDigest.init)
    }

    // MARK: Helpers

    private func resolveScope(folder: String?, collection: String?, tag: String?) -> LibraryScope? {
        let suppliedCount = [folder, collection, tag].compactMap { $0 }.count
        guard suppliedCount <= 1 else { return nil }

        if let folder {
            guard case .folder(let id)? = LibraryReference(folder) else { return nil }
            return .folderTree(id)
        }
        if let collection {
            guard case .collection(let id)? = LibraryReference(collection) else { return nil }
            return .collection(id)
        }
        if let tag {
            guard case .tag(let id)? = LibraryReference(tag) else { return nil }
            return .tag(id)
        }
        return .allObjects
    }
}

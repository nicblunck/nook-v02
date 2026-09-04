import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

/// The app's view state over a library.
///
/// Every read goes through `LibraryService` and arrives as a `Sendable`
/// snapshot; the UI never holds a SwiftData model and never queries the store
/// directly. That is what keeps the privacy broker underneath the interface
/// rather than beside it.
@MainActor
@Observable
final class LibraryModel {
    let library: Library

    // MARK: Navigation state

    var scope: LibraryScope = .inbox { didSet { onScopeChanged(from: oldValue) } }
    var sort: ObjectSort = .default { didSet { Task { await refreshContents() } } }
    var searchText: String = "" { didSet { scheduleSearchRefresh() } }
    var selection: Set<ObjectID> = []
    var previewedObjectID: ObjectID?
    var isInspectorPresented = false

    // MARK: Contents

    private(set) var contents: LocationContents = .empty
    private(set) var breadcrumbs: [FolderSnapshot] = []
    private(set) var folderTree: [FolderNode] = []
    private(set) var collections: [CollectionSnapshot] = []
    private(set) var tags: [TagSnapshot] = []
    private(set) var counts: [ScopeCountKey: Int] = [:]

    // MARK: Transient state

    private(set) var importProgress: ImportProgress?
    var alert: LibraryAlert?

    /// The authenticated state every read is made under. Hidden and locked
    /// content stays out of reach until the authentication flow raises this.
    private(set) var accessContext: AccessContext = .standard

    private var searchTask: Task<Void, Never>?

    init(library: Library) {
        self.library = library
    }

    private var service: LibraryService { library.service }

    // MARK: Refresh

    func refreshAll() async {
        await refreshSidebar()
        await refreshContents()
    }

    func refreshSidebar() async {
        let access = accessContext
        async let collections = service.collections(in: access)
        async let tags = service.tags(in: access)
        self.folderTree = await loadFolderTree(under: nil)
        self.collections = await collections
        self.tags = await tags
        await refreshCounts()
    }

    func refreshContents() async {
        let access = accessContext
        let query = ObjectQuery(scope: scope, searchText: searchText, sort: sort)

        let objects = await service.objects(matching: query, in: access)
        let folders: [FolderSnapshot]
        if case .folder(let id) = scope {
            folders = await service.subfolders(of: id, in: access)
            breadcrumbs = await service.folderPath(to: id, in: access)
        } else {
            folders = []
            breadcrumbs = []
        }

        contents = LocationContents(folders: folders, objects: objects)
        selection = selection.filter { id in objects.contains { $0.id == id } }
    }

    private func refreshCounts() async {
        let access = accessContext
        var updated: [ScopeCountKey: Int] = [:]
        for key in ScopeCountKey.allCases {
            updated[key] = await service.objectCount(in: key.scope, access: access)
        }
        counts = updated
    }

    private func onScopeChanged(from previous: LibraryScope) {
        guard previous != scope else { return }
        selection = []
        searchText = ""
        Task { await refreshContents() }
    }

    /// Search runs after a short pause so typing does not re-query per keystroke.
    private func scheduleSearchRefresh() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await refreshContents()
        }
    }

    // MARK: Import

    func importItems(_ items: [ImportItem]) async {
        guard !items.isEmpty else { return }
        let destination = ImportDestination(scope: scope)

        let report = await service.importItems(items, into: destination) { [weak self] progress in
            Task { @MainActor in self?.importProgress = progress.isFinished ? nil : progress }
        }
        importProgress = nil
        await refreshAll()

        if report.hasFailures {
            alert = LibraryAlert(
                title: "Some items couldn't be imported",
                message: report.failures.compactMap {
                    if case .failed(let name, let error) = $0 { "\(name): \(error)" } else { nil }
                }.joined(separator: "\n")
            )
        } else if report.duplicateCount > 0 {
            let count = report.duplicateCount
            alert = LibraryAlert(
                title: count == 1 ? "One item was already in your library" : "\(count) items were already in your library",
                message: "They were added again as separate items, sharing one stored copy of the file."
            )
        }
    }

    func importFiles(at urls: [URL]) async {
        await importItems(urls.map { ImportItem.file(url: $0) })
    }

    // MARK: Mutations

    func createFolder(named name: String) async {
        let parent: FolderID? = if case .folder(let id) = scope { id } else { nil }
        await perform { try await self.library.service.createFolder(named: name, in: parent) }
    }

    func rename(folder id: FolderID, to name: String) async {
        await perform { try await self.library.service.renameFolder(id, to: name) }
    }

    func deleteFolder(_ id: FolderID) async {
        if case .folder(id) = scope { scope = .inbox }
        await perform { try await self.library.service.deleteFolder(id) }
    }

    func move(_ ids: [ObjectID], to destination: FolderID?) async {
        await perform { try await self.library.service.moveObjects(ids, to: destination) }
    }

    func setFavorite(_ isFavorite: Bool, for ids: [ObjectID]) async {
        await perform { try await self.library.service.setFavorite(isFavorite, for: ids) }
    }

    func delete(_ ids: [ObjectID]) async {
        if let previewed = previewedObjectID, ids.contains(previewed) { previewedObjectID = nil }
        await perform { try await self.library.service.delete(ids) }
    }

    func restore(_ ids: [ObjectID]) async {
        await perform { try await self.library.service.restore(ids) }
    }

    func permanentlyDelete(_ ids: [ObjectID]) async {
        await perform { try await self.library.service.permanentlyDelete(ids) }
    }

    func update(_ id: ObjectID, title: String? = nil, notes: String? = nil) async {
        await perform { try await self.library.service.updateObject(id, title: title, notes: notes) }
    }

    func addTag(_ name: String, to ids: [ObjectID]) async {
        await perform { try await self.library.service.addTag(named: name, to: ids) }
    }

    func removeTag(_ id: TagID, from ids: [ObjectID]) async {
        await perform { try await self.library.service.removeTag(id, from: ids) }
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
            await refreshAll()
        } catch {
            alert = LibraryAlert(title: "Something went wrong", message: error.localizedDescription)
        }
    }

    // MARK: Derived

    var selectedObjects: [ObjectSnapshot] {
        contents.objects.filter { selection.contains($0.id) }
    }

    var previewedObject: ObjectSnapshot? {
        previewedObjectID.flatMap { id in contents.objects.first { $0.id == id } }
    }

    /// Every folder in the library, flattened and indented, for the move menu.
    var allFolders: [(folder: FolderSnapshot, depth: Int)] {
        func flatten(_ nodes: [FolderNode], depth: Int) -> [(FolderSnapshot, Int)] {
            nodes.flatMap { [($0.folder, depth)] + flatten($0.children, depth: depth + 1) }
        }
        return flatten(folderTree, depth: 0)
    }

    /// Builds the sidebar's folder tree. Depth is capped so a cycle introduced
    /// by a bad sync can never hang the sidebar.
    private func loadFolderTree(under parent: FolderID?, depth: Int = 0) async -> [FolderNode] {
        guard depth < 24 else { return [] }
        let access = accessContext
        let folders = if let parent {
            await service.subfolders(of: parent, in: access)
        } else {
            await service.rootFolders(in: access)
        }
        var nodes: [FolderNode] = []
        for folder in folders {
            let children = folder.subfolderCount > 0
                ? await loadFolderTree(under: folder.id, depth: depth + 1)
                : []
            nodes.append(FolderNode(folder: folder, children: children))
        }
        return nodes
    }

    func adjacentObject(to id: ObjectID, offset: Int) -> ObjectSnapshot? {
        guard let index = contents.objects.firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + offset
        guard contents.objects.indices.contains(target) else { return nil }
        return contents.objects[target]
    }
}

/// One folder and its subtree, as the sidebar draws it.
struct FolderNode: Identifiable, Hashable {
    let folder: FolderSnapshot
    var children: [FolderNode]

    var id: FolderID { folder.id }
    /// `nil` rather than an empty array, so a leaf draws no disclosure arrow.
    var outlineChildren: [FolderNode]? { children.isEmpty ? nil : children }
}

struct LibraryAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// The system destinations whose counts the sidebar shows.
enum ScopeCountKey: Hashable, CaseIterable {
    case inbox, favorites, allObjects, recentlyDeleted

    var scope: LibraryScope {
        switch self {
        case .inbox: .inbox
        case .favorites: .favorites
        case .allObjects: .allObjects
        case .recentlyDeleted: .recentlyDeleted
        }
    }
}

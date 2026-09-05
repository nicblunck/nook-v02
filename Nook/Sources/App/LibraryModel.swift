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
    let settings: AppSettings

    // MARK: Navigation state

    var scope: LibraryScope = .inbox { didSet { onScopeChanged(from: oldValue) } }
    var searchText: String = "" { didSet { scheduleSearchRefresh() } }
    var selection: Set<ObjectID> = []
    var previewedObjectID: ObjectID?
    var isInspectorPresented = false

    // MARK: Presented surfaces
    //
    // Held on the model rather than in view state so the menu bar can raise
    // the same prompts the sidebar and canvas do.

    var isImporterPresented = false
    var isGlobalSearchPresented = false
    var isSettingsPresented = false
    /// Home is a destination rather than a query, so it sits beside the scope
    /// rather than inside it.
    var isShowingHome = true
    var namingPrompt: NamingPrompt?
    var searchFieldFocusRequests = 0

    /// The scope pill in the search field. Removing it widens the same query
    /// to the whole library; it is not a separate search.
    var searchTokens: [SearchScopeToken] = []

    // MARK: Contents

    private(set) var contents: LocationContents = .empty
    private(set) var breadcrumbs: [FolderSnapshot] = []
    private(set) var folderTree: [FolderNode] = []
    private(set) var collections: [CollectionSnapshot] = []
    private(set) var tags: [TagSnapshot] = []
    private(set) var counts: [ScopeCountKey: Int] = [:]
    private(set) var homeSections: [HomeSection] = []

    // MARK: Transient state

    private(set) var importProgress: ImportProgress?
    var alert: LibraryAlert?

    /// The authenticated state every read is made under. Hidden and locked
    /// content stays out of reach until the authentication flow raises this.
    private(set) var accessContext: AccessContext = .standard

    private var searchTask: Task<Void, Never>?

    // MARK: Presentation
    //
    // The arrangement on screen: a location's remembered settings if it has
    // any, otherwise the global default. Changes are temporary unless the user
    // has asked this location to remember them.

    private(set) var preferences: LocationViewPreferences = .systemDefault
    private(set) var isRememberingLocation = false
    private(set) var canRememberLocation = false

    var sort: ObjectSort { preferences.sort }
    var viewMode: LibraryViewMode { preferences.viewMode }
    var foldersFirst: Bool { preferences.foldersFirst }

    init(library: Library, settings: AppSettings) {
        self.library = library
        self.settings = settings
        self.preferences = settings.defaultPreferences
    }

    private var service: LibraryService { library.service }

    // MARK: Refresh

    func refreshAll() async {
        await refreshSidebar()
        await loadPreferences()
        await refreshContents()
        await refreshHome()
    }

    /// Home's sections. Restrained on purpose — a way back into recent work,
    /// not a dashboard.
    func refreshHome() async {
        let access = accessContext
        var sections: [HomeSection] = []
        for definition in HomeSection.defaults {
            let objects = await service.objects(
                matching: ObjectQuery(scope: definition.scope,
                                      sort: ObjectSort(field: .dateAdded, ascending: false),
                                      limit: 12),
                in: access
            )
            guard !objects.isEmpty || definition.showsWhenEmpty else { continue }
            sections.append(HomeSection(definition: definition, objects: objects))
        }
        homeSections = sections
    }

    // MARK: Presentation

    /// Loads whatever this location has been asked to remember, falling back to
    /// the global default so an unremembered location never inherits the last
    /// one's arrangement.
    func loadPreferences() async {
        canRememberLocation = await service.canRememberPreferences(for: scope)
        if let remembered = await service.rememberedPreferences(for: scope) {
            preferences = remembered
            isRememberingLocation = true
        } else {
            preferences = settings.defaultPreferences
            isRememberingLocation = false
        }
    }

    func setViewMode(_ mode: LibraryViewMode) async {
        var updated = preferences
        updated.viewMode = mode
        await apply(updated)
    }

    func setSort(_ sort: ObjectSort) async {
        var updated = preferences
        updated.sort = sort
        await apply(updated)
    }

    func setFoldersFirst(_ foldersFirst: Bool) async {
        var updated = preferences
        updated.foldersFirst = foldersFirst
        await apply(updated)
    }

    /// Turning this on makes the current arrangement this location's own.
    /// Turning it off leaves what is on screen alone but stops persisting it,
    /// so the location follows the global default again next time.
    func setRememberingLocation(_ isRemembering: Bool) async {
        guard canRememberLocation else { return }
        isRememberingLocation = isRemembering
        do {
            if isRemembering {
                try await service.rememberPreferences(preferences, for: scope)
            } else {
                try await service.forgetPreferences(for: scope)
            }
        } catch {
            alert = LibraryAlert(title: "Couldn't save this view", message: error.localizedDescription)
        }
    }

    /// Promotes the current arrangement to the global default. Explicit, so a
    /// one-off change in one folder never silently becomes the rule everywhere.
    func useCurrentPreferencesAsDefault() {
        settings.defaultPreferences = preferences
    }

    private func apply(_ updated: LocationViewPreferences) async {
        preferences = updated
        if isRememberingLocation {
            try? await service.rememberPreferences(updated, for: scope)
        }
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

    /// Where the canvas is currently reading from.
    ///
    /// While searching, the scope pill decides — removing it expands the query
    /// to the whole library without changing what is selected in the sidebar.
    var effectiveScope: LibraryScope {
        guard !searchText.isEmpty else { return scope }
        return searchTokens.first?.scope ?? .allObjects
    }

    func refreshContents() async {
        let access = accessContext
        let query = ObjectQuery(scope: effectiveScope, searchText: searchText, sort: sort)

        let objects = await service.objects(matching: query, in: access)
        let folders: [FolderSnapshot]
        if case .folder(let id) = effectiveScope {
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
        Task {
            await loadPreferences()
            await refreshContents()
        }
    }

    /// Search runs after a short pause so typing does not re-query per keystroke.
    private func scheduleSearchRefresh() {
        // Typing in a location scopes the search there, shown as a removable
        // pill. Clearing the field puts the pill away again.
        if searchText.isEmpty {
            searchTokens = []
        } else if searchTokens.isEmpty, let token = SearchScopeToken(scope: scope, model: self) {
            searchTokens = [token]
        }

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
        extractPendingContent()
        fetchPendingLinkMetadata()

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

    /// Brings in whatever is on the pasteboard — a copied file, a copied web
    /// address, or a copied picture.
    func importPasteboard() async {
        let items = PasteImporter.items()
        guard !items.isEmpty else {
            alert = LibraryAlert(
                title: "Nothing to paste",
                message: "The clipboard doesn't hold a file, a link, or an image."
            )
            return
        }
        await importItems(items)
    }

    // MARK: External navigation

    /// Acts on a request left by an intent — or later a share extension or a
    /// Spotlight result — that may have arrived before any window existed.
    func handle(_ request: AppNavigator.Request) async {
        switch request {
        case .scope(let requested):
            scope = requested
            await loadPreferences()
            await refreshContents()

        case .object(let id):
            guard let object = await library.service.object(id, in: accessContext) else { return }
            scope = object.folderID.map { LibraryScope.folder($0) } ?? .inbox
            await loadPreferences()
            await refreshContents()
            selection = [id]
            if object.kind == .link, let url = object.sourceURL {
                await MainActor.run { OpenExternally.open(url) }
            } else {
                previewedObjectID = id
            }
        }
    }

    // MARK: Derived content

    /// Works through the text-extraction backlog in the background.
    ///
    /// Nothing in the interface waits on this: extraction feeds the machine-
    /// readable layer — content search, Siri, MCP, on-device summarisation —
    /// rather than anything on screen.
    func extractPendingContent() {
        Task.detached(priority: .background) { [service = library.service] in
            await service.extractPendingText()
        }
    }

    /// Fills in page metadata for links saved without it — from the share
    /// sheet, or while offline. Runs quietly; nothing on screen waits for it.
    func fetchPendingLinkMetadata() {
        Task { [weak self] in
            guard let self else { return }
            let service = library.service
            let thumbnails = library.thumbnails
            let pending = await service.linksAwaitingMetadata()
            guard !pending.isEmpty else { return }

            for id in pending {
                guard let object = await service.object(id, in: accessContext),
                      let url = object.sourceURL,
                      let result = await LinkMetadataFetcher.fetch(for: url)
                else { continue }

                try? await service.applyLinkMetadata(result.metadata, to: id)
                if let imageData = result.previewImageData {
                    await thumbnails.storePreviewImage(imageData, for: id)
                }
            }
            await refreshAll()
        }
    }

    // MARK: Originals

    /// A local file URL for an object's original, when the bytes are already
    /// on this device. Returns nil for a locked object, which arrives without
    /// a blob descriptor, and for one whose original has not been downloaded.
    nonisolated func localURL(for object: ObjectSnapshot) -> URL? {
        guard let descriptor = object.blob else { return nil }
        return library.blobStore.localURL(for: descriptor)
    }

    nonisolated func localURLs(for objects: [ObjectSnapshot]) -> [URL] {
        objects.compactMap { localURL(for: $0) }
    }

    // MARK: Mutations

    func createFolder(named name: String, in parent: FolderID?) async {
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

    // MARK: Collections

    func createCollection(named name: String, adding ids: [ObjectID] = []) async {
        await perform {
            let created = try await self.library.service.createCollection(named: name)
            if !ids.isEmpty {
                try await self.library.service.addObjects(ids, toCollection: created.id)
            }
        }
    }

    func addToCollection(_ collection: CollectionID, objects ids: [ObjectID]) async {
        await perform { try await self.library.service.addObjects(ids, toCollection: collection) }
    }

    /// Removes membership only — the objects stay exactly where they live.
    func removeFromCollection(_ collection: CollectionID, objects ids: [ObjectID]) async {
        await perform { try await self.library.service.removeObjects(ids, fromCollection: collection) }
    }

    func renameCollection(_ id: CollectionID, to name: String) async {
        await perform { try await self.library.service.renameCollection(id, to: name) }
    }

    func deleteCollection(_ id: CollectionID) async {
        if case .collection(id) = scope { scope = .inbox }
        await perform { try await self.library.service.deleteCollection(id) }
    }

    /// Drops `moved` in ahead of `target` in the collection's manual order.
    func reorder(_ moved: [ObjectID], before target: ObjectID) async {
        guard case .collection(let id) = scope, !moved.contains(target) else { return }
        var order = contents.objects.map(\.id)
        order.removeAll { moved.contains($0) }
        guard let index = order.firstIndex(of: target) else { return }
        order.insert(contentsOf: moved, at: index)
        await perform { try await self.library.service.reorderCollection(id, objectOrder: order) }
    }

    // MARK: Appearance

    func setAppearance(_ appearance: EntityAppearance, for reference: LibraryReference) async {
        await perform {
            switch reference {
            case .folder(let id):
                try await self.library.service.setAppearance(appearance, forFolder: id)
            case .collection(let id):
                try await self.library.service.setAppearance(appearance, forCollection: id)
            case .tag(let id):
                try await self.library.service.setAppearance(appearance, forTag: id)
            case .object:
                break
            }
        }
    }

    // MARK: Tags

    func renameTag(_ id: TagID, to name: String) async {
        await perform { try await self.library.service.renameTag(id, to: name) }
    }

    func deleteTag(_ id: TagID) async {
        if case .tag(id) = scope { scope = .inbox }
        await perform { try await self.library.service.deleteTag(id) }
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

    /// The canvas as one ordered sequence.
    ///
    /// With Folders First on, locations lead and their contents follow. With it
    /// off, folders sort inline among the objects — but only by a key both
    /// kinds actually have, so sorting by size or duration keeps folders first
    /// rather than inventing a value for them.
    var canvasItems: [CanvasItem] {
        let folders = contents.folders.map(CanvasItem.folder)
        let objects = contents.objects.map(CanvasItem.object)

        guard !preferences.foldersFirst, !folders.isEmpty else {
            return folders + objects
        }

        switch sort.field {
        case .name:
            let merged = (folders + objects).sorted {
                $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending
            }
            return sort.ascending ? merged : merged.reversed()
        case .dateAdded:
            let merged = (folders + objects).sorted { $0.sortDate < $1.sortDate }
            return sort.ascending ? merged : merged.reversed()
        case .dateCreated, .kind, .size, .manual:
            return folders + objects
        }
    }

    var selectedObjects: [ObjectSnapshot] {
        contents.objects.filter { selection.contains($0.id) }
    }

    var currentFolderID: FolderID? {
        if case .folder(let id) = scope { return id }
        return nil
    }

    func requestSearchFieldFocus() {
        searchFieldFocusRequests += 1
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

/// One band on the Home screen.
struct HomeSection: Identifiable {
    struct Definition {
        let scope: LibraryScope
        let title: String
        let symbolName: String
        let showsWhenEmpty: Bool
    }

    let definition: Definition
    let objects: [ObjectSnapshot]

    var id: LibraryScope { definition.scope }
    var title: String { definition.title }
    var symbolName: String { definition.symbolName }
    var scope: LibraryScope { definition.scope }

    /// The default sections. Customising which sections appear, and their
    /// order, is deliberately left until after the core loop is stable.
    static let defaults: [Definition] = [
        Definition(scope: .inbox, title: "Inbox", symbolName: "tray", showsWhenEmpty: true),
        Definition(scope: .recent, title: "Recent", symbolName: "clock", showsWhenEmpty: false)
    ]
}

/// Where the sidebar can point. Home is not a query over objects, so it is not
/// a scope.
enum LibraryDestination: Hashable {
    case home
    case scope(LibraryScope)
}

/// A row in the canvas: a location or a thing.
enum CanvasItem: Identifiable, Hashable {
    case folder(FolderSnapshot)
    case object(ObjectSnapshot)

    var id: UUID {
        switch self {
        case .folder(let folder): folder.id.uuid
        case .object(let object): object.id.uuid
        }
    }

    var sortName: String {
        switch self {
        case .folder(let folder): folder.name
        case .object(let object): object.title
        }
    }

    var sortDate: Date {
        switch self {
        case .folder(let folder): folder.dateAdded
        case .object(let object): object.dateAdded
        }
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

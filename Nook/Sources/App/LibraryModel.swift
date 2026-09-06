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
    /// Where the keyboard is on the canvas.
    ///
    /// Kept apart from the selection because the two answer different
    /// questions: the selection is what the batch actions act on, the cursor
    /// is where the next arrow key starts from. A folder can hold the cursor
    /// without ever joining a selection — folders are places, not things.
    var cursor: CanvasItemID?
    /// Where a shift-extended selection is measured from, so extending stays
    /// anchored to the item the user actually started at rather than to
    /// whichever element an unordered set happens to yield first.
    var selectionAnchor: ObjectID?
    var previewedObjectID: ObjectID?
    var isInspectorPresented = false

    // MARK: Keyboard focus
    //
    // Which column the keyboard is talking to is decided here, in one place,
    // rather than by two `@FocusState`s racing each other. SwiftUI focus and
    // AppKit's first responder are separate systems that do not agree, and a
    // sidebar list has to genuinely hold the keyboard — that is what makes
    // macOS paint its own selection, full width and correctly contrasted,
    // instead of the app drawing a selection by hand that says nothing about
    // where the keyboard actually is.

    /// The column listening to the keyboard. The sidebar starts with it,
    /// because the app opens on Home, which has no canvas to navigate.
    private(set) var keyboardPane: KeyboardPane = .sidebar
    /// Bumped every time a column is asked to take the keyboard, so asking for
    /// one that is already listening still works — after a sheet closes, say,
    /// when the pane has not changed but the window's first responder has.
    private(set) var keyboardFocusRequest = 0
    /// Bumped when the keyboard is walked into the canvas from the sidebar
    /// rather than put there by a click. The canvas answers by lighting
    /// something up: arriving with nothing lit looks exactly like the key
    /// having done nothing. A click cannot use this — clicking the space
    /// between items means "select nothing", and lighting the first item would
    /// undo that.
    private(set) var canvasEntryRequest = 0

    /// Where the keyboard is on Home.
    ///
    /// Home needs a cursor of its own because it is not a scope: its bands are
    /// separate queries over the library, so the canvas cursor — which walks
    /// the contents of one place — has nothing to walk here.
    var homeCursor: HomeTileID?

    /// Which folders are open in the sidebar.
    ///
    /// Held here rather than inside an `OutlineGroup` because the left and
    /// right arrows have to be able to open and close a folder, and a control
    /// that keeps its own expansion state privately cannot be asked to.
    var expandedFolders: Set<FolderID> = []

    /// Hands the keyboard to a column.
    func focus(_ pane: KeyboardPane) {
        keyboardPane = pane
        keyboardFocusRequest += 1
    }

    /// What Tab does. With two columns, forward and back are the same move, so
    /// Shift-Tab does the same thing.
    func focusOtherPane() { focus(keyboardPane.next) }

    /// Steps the keyboard out of the sidebar and into the canvas beside it,
    /// landing on something rather than merely arriving.
    func enterCanvas() {
        focus(.canvas)
        canvasEntryRequest += 1
    }

    // MARK: Presented surfaces
    //
    // Held on the model rather than in view state so the menu bar can raise
    // the same prompts the sidebar and canvas do.

    var isImporterPresented = false
    var isGlobalSearchPresented = false
    var isSettingsPresented = false
    /// Raised while the user picks a folder to export originals into.
    var isExportPickerPresented = false
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
    var importFailure: ImportFailure?

    /// The authenticated state every read is made under. Hidden and locked
    /// content stays out of reach until the authentication flow raises this,
    /// which only `LibraryModel+Privacy` does, and only after the device owner
    /// has said yes.
    var accessContext: AccessContext = .standard

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
    var itemScale: Double { preferences.itemScale }

    /// Who vouches for the device owner before hidden or locked content moves.
    /// Injected so the app's tests can answer without a device.
    let authenticator: any LibraryAuthenticating

    init(library: Library,
         settings: AppSettings,
         authenticator: any LibraryAuthenticating = DeviceAuthenticator()) {
        self.library = library
        self.settings = settings
        self.authenticator = authenticator
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
        let present = Set(homeOrder)
        if let current = homeCursor, !present.contains(current) { homeCursor = nil }
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

    /// Live while the size control is being dragged. Size is a drawing
    /// detail — nothing about which items belong here changes — so this moves
    /// what is on screen without re-querying the library or writing anything.
    func setItemScale(_ scale: Double) {
        preferences.itemScale = LocationViewPreferences.clamped(scale: scale)
    }

    /// Called once the control is let go, so a drag across the whole range
    /// writes one arrangement rather than a hundred.
    func commitItemScale() async {
        guard isRememberingLocation else { return }
        try? await service.rememberPreferences(preferences, for: scope)
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
        pruneHistory()
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
        } else if effectiveScope == .hidden {
            // Hidden holds folders as well as objects, which is what makes it
            // a place rather than a list of loose things.
            folders = await service.hiddenFolders(in: access)
            breadcrumbs = []
        } else {
            folders = []
            breadcrumbs = []
        }

        contents = LocationContents(folders: folders, objects: objects)
        selection = selection.filter { id in objects.contains { $0.id == id } }
        // A deletion, a move or an arriving import can take whatever the
        // cursor was resting on out from under it.
        let present = Set(canvasItems.map(\.itemID))
        if let current = cursor, !present.contains(current) { cursor = nil }
        if let anchor = selectionAnchor, !selection.contains(anchor) { selectionAnchor = nil }
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
        // Opening a folder on the canvas sets the scope directly, and that is
        // a step in its own right. A step made through `navigate(to:)`, or by
        // going back, is refused by `pushHistory` while it is being applied.
        pushHistory(.scope(previous))
        selection = []
        selectionAnchor = nil
        cursor = nil
        searchText = ""
        Task {
            // Hidden closes behind you: stepping out of it, or out of a folder
            // inside it, puts everything back out of reach so coming back asks
            // again.
            await closeHidden()
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

    // MARK: History
    //
    // Back and Forward follow the path the user walked, not the shape of the
    // folder tree, so returning from a collection lands where they came from
    // rather than one level up something they were never in. Home is a stop
    // like any other.

    private var backStack: [LibraryDestination] = []
    private var forwardStack: [LibraryDestination] = []

    /// Raised while a destination is being applied. A single step can touch
    /// both `isShowingHome` and `scope`; this keeps that from recording twice.
    private var isTraversingHistory = false

    /// Where the canvas is pointing right now.
    var destination: LibraryDestination { isShowingHome ? .home : .scope(scope) }

    var canGoBack: Bool { previewedObjectID != nil || !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The way the interface changes destination. Going through here is what
    /// keeps Back honest when leaving Home for a scope, which is two property
    /// changes for one step the user took.
    func navigate(to destination: LibraryDestination) {
        let previous = self.destination
        guard previous != destination else { return }
        pushHistory(previous)
        apply(destination)
    }

    func goBack() {
        // Preview sits in front of the canvas rather than beside it, so the
        // first step back is out of preview and into the place it came from.
        if previewedObjectID != nil {
            previewedObjectID = nil
            return
        }
        guard let target = backStack.popLast() else { return }
        forwardStack.append(destination)
        apply(target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(destination)
        apply(target)
    }

    private func apply(_ destination: LibraryDestination) {
        isTraversingHistory = true
        defer { isTraversingHistory = false }

        // Leaving preview: a step through history is a change of place, and the
        // canvas is what a place shows.
        previewedObjectID = nil
        switch destination {
        case .home:
            isShowingHome = true
        case .scope(let scope):
            isShowingHome = false
            self.scope = scope
        }
    }

    private func pushHistory(_ destination: LibraryDestination) {
        guard !isTraversingHistory, backStack.last != destination else { return }
        backStack.append(destination)
        forwardStack.removeAll()
        // Far enough back to retrace an afternoon, not far enough to remember
        // every folder ever opened.
        if backStack.count > 64 { backStack.removeFirst() }
    }

    /// Drops destinations that no longer exist, so Back never lands on a place
    /// that has been deleted.
    ///
    /// Deleting a folder takes its subfolders with it, and a sync can retire a
    /// place this device never touched. Rather than name every casualty at the
    /// point of deletion, history is reconciled against what the sidebar has
    /// just been told actually exists.
    private func pruneHistory() {
        let folders = Set(allFolders.map(\.folder.id))
        let collectionIDs = Set(collections.map(\.id))
        let tagIDs = Set(tags.map(\.id))

        func survives(_ destination: LibraryDestination) -> Bool {
            guard case .scope(let scope) = destination else { return true }
            switch scope {
            case .folder(let id): return folders.contains(id)
            case .collection(let id): return collectionIDs.contains(id)
            case .tag(let id): return tagIDs.contains(id)
            // Back never walks into Hidden: it closed when the user left, and
            // a step through history is not somewhere to be asked for a
            // fingerprint.
            case .hidden: return isShowingHiddenContent
            default: return true
            }
        }

        backStack.removeAll { !survives($0) }
        forwardStack.removeAll { !survives($0) }
    }

    // MARK: Selection

    /// Raised while a text field owns the keyboard.
    var isTextEntryFocused = false

    /// Whether the keyboard belongs to text rather than to the canvas.
    ///
    /// A menu command outranks the field editor in SwiftUI, so any command on
    /// a plain character — or on a shortcut a field wants for itself — has to
    /// stand down while someone is typing, or it takes the keystroke instead.
    /// The naming prompt counts: it is an alert, but the field in it is still
    /// a field.
    var isTypingText: Bool { isTextEntryFocused || namingPrompt != nil }

    var canSelectAll: Bool { !isTypingText && !contents.objects.isEmpty }

    /// Selects the objects on the canvas. Folders are places rather than
    /// things, so they are not part of a selection the batch actions can act on.
    func selectAll() {
        selection = Set(contents.objects.map(\.id))
    }

    func deselectAll() {
        selection = []
        selectionAnchor = nil
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
            let failedItems = zip(items, report.results).compactMap { item, result in
                if case .failed = result { item } else { nil }
            }
            importFailure = ImportFailure(
                items: failedItems,
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
            navigate(to: .scope(requested))
            await loadPreferences()
            await refreshContents()

        case .object(let id):
            guard let object = await library.service.object(id, in: accessContext) else { return }
            navigate(to: .scope(object.folderID.map { LibraryScope.folder($0) } ?? .inbox))
            await loadPreferences()
            await refreshContents()
            // Through the same opening as a click, so an intent cannot show
            // what a lock would have withheld on the canvas.
            openObject(contents.objects.first { $0.id == id } ?? object)
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

    // MARK: Export
    //
    // Getting an original back out is as ordinary as putting one in: the bytes
    // were never transformed on the way in, so they leave byte-for-byte. The
    // library is where files are kept, not where they are captured.

    /// The objects a destination folder is being chosen for.
    private var pendingExport: [ObjectSnapshot] = []

    var canExport: Bool { !selectedObjects.isEmpty || previewedObject != nil }

    /// Asks for somewhere to write to. Objects whose original is not on this
    /// device are dropped here rather than failing one by one at the copy.
    func beginExport(of objects: [ObjectSnapshot]) {
        let available = objects.filter { localURL(for: $0) != nil }
        guard !available.isEmpty else {
            alert = LibraryAlert(
                title: objects.count == 1 ? "No original to export" : "No originals to export",
                message: "The stored file isn't on this device."
            )
            return
        }
        pendingExport = available
        isExportPickerPresented = true
    }

    func cancelExport() {
        pendingExport = []
    }

    func completeExport(to directory: URL) async {
        let objects = pendingExport
        pendingExport = []
        guard !objects.isEmpty else { return }

        // A folder handed over by the picker is ours only while the scope is
        // held open, which on iOS is the difference between writing and being
        // refused.
        let isScoped = directory.startAccessingSecurityScopedResource()
        defer { if isScoped { directory.stopAccessingSecurityScopedResource() } }

        var failures: [String] = []
        for object in objects {
            guard let source = localURL(for: object) else {
                failures.append(object.title)
                continue
            }
            // A stored filename is data, not a path: a separator in it would
            // otherwise aim the copy at a directory that isn't there.
            let name = (object.originalFilename ?? source.lastPathComponent)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            do {
                try FileManager.default.copyItem(
                    at: source, to: Self.unusedURL(in: directory, named: name)
                )
            } catch {
                failures.append(object.title)
            }
        }

        guard !failures.isEmpty else { return }
        alert = LibraryAlert(
            title: failures.count == 1
                ? "One item couldn't be exported"
                : "\(failures.count) items couldn't be exported",
            message: failures.joined(separator: "\n")
        )
    }

    /// Objects share stored files and can carry the same original filename, so
    /// an export names its way around a collision rather than overwriting
    /// whatever was already in the folder.
    private static func unusedURL(in directory: URL, named name: String) -> URL {
        let exists = { (url: URL) in
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
        let candidate = directory.appending(path: name)
        guard exists(candidate) else { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for index in 2...999 {
            let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = directory.appending(path: numbered)
            if !exists(url) { return url }
        }
        return directory.appending(path: "\(base) \(UUID().uuidString)")
    }

    // MARK: Mutations

    func createFolder(named name: String, in parent: FolderID?) async {
        await perform { try await self.library.service.createFolder(named: name, in: parent) }
    }

    func rename(folder id: FolderID, to name: String) async {
        await perform { try await self.library.service.renameFolder(id, to: name) }
    }

    func moveFolder(_ id: FolderID, to parent: FolderID?) async {
        await perform { try await self.library.service.moveFolder(id, to: parent) }
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

    func perform(_ work: @escaping () async throws -> Void) async {
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

    func stepPreview(_ offset: Int) {
        guard let current = previewedObjectID,
              let next = adjacentObject(to: current, offset: offset)
        else { return }
        previewedObjectID = next.id
        selection = [next.id]
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

/// One tile on Home: an object, in the band it is showing in.
///
/// The band is part of the identity because Home's sections are independent
/// queries — anything recently imported and still unsorted is in both Inbox
/// and Recent — so an object id alone names two tiles at once.
struct HomeTileID: Hashable, Sendable {
    let scope: LibraryScope
    let object: ObjectID
}

/// Which column the keyboard is talking to.
enum KeyboardPane: Hashable, CaseIterable {
    case sidebar
    case canvas

    var next: KeyboardPane { self == .sidebar ? .canvas : .sidebar }
}

/// Which item on the canvas, and which kind of item it is.
enum CanvasItemID: Hashable, Sendable {
    case folder(FolderID)
    case object(ObjectID)

    var uuid: UUID {
        switch self {
        case .folder(let id): id.uuid
        case .object(let id): id.uuid
        }
    }

    var objectID: ObjectID? {
        if case .object(let id) = self { return id }
        return nil
    }
}

/// A row in the canvas: a location or a thing.
enum CanvasItem: Identifiable, Hashable {
    case folder(FolderSnapshot)
    case object(ObjectSnapshot)

    var id: UUID { itemID.uuid }

    /// The identity keyboard navigation works in, which — unlike `id` — still
    /// knows whether it is pointing at a place or a thing.
    var itemID: CanvasItemID {
        switch self {
        case .folder(let folder): .folder(folder.id)
        case .object(let object): .object(object.id)
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

struct ImportFailure: Identifiable {
    let id = UUID()
    let items: [ImportItem]
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

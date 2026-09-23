import SwiftUI
import UniformTypeIdentifiers
import NookLibrary
#if os(iOS)
import UIKit
#endif

/// One explicit batch of things that have just entered the library.
///
/// Refreshes caused by navigation, search, or sync deliberately don't create
/// one of these. Views can therefore animate real arrivals without replaying
/// their entrance whenever a query is rebuilt.
struct LibraryArrival: Equatable {
    let revision: Int
    let destination: LibraryDestination
    var objectIDs: [ObjectID] = []
    var folderIDs: [FolderID] = []
    var collectionIDs: [CollectionID] = []

    func objectOrder(_ id: ObjectID) -> Int? { objectIDs.firstIndex(of: id) }
    func folderOrder(_ id: FolderID) -> Int? { folderIDs.firstIndex(of: id) }
    func collectionOrder(_ id: CollectionID) -> Int? { collectionIDs.firstIndex(of: id) }
}

/// A short-lived confirmation for a completed library action.
///
/// The resource stays unresolved until SwiftUI renders it, so the toast uses
/// the window's current locale rather than whichever locale was active when
/// the operation began.
struct LibraryToast: Equatable, Identifiable {
    let id: Int
    let message: LocalizedStringResource
    let systemImage: String
    let tint: LibraryToastTint
}

/// Semantic colors used to distinguish toast actions at a glance.
enum LibraryToastTint: Equatable {
    case green
    case blue
    case yellow
    case purple
    case orange
    case red
}

/// A transient, single-select lens over the current library location.
///
/// These broad categories deliberately sit above `ObjectKind`: a screenshot
/// is still an image to someone browsing, while PDFs and otherwise-generic
/// files both belong under Documents. `nil` on the model means no lens at all.
enum LibraryContentFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case images
    case documents
    case audio
    case video
    case links
    case folders

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .images: "Images"
        case .documents: "Documents"
        case .audio: "Audio"
        case .video: "Video"
        case .links: "Links"
        case .folders: "Folders"
        }
    }

    var systemImage: String {
        switch self {
        case .images: "photo"
        case .documents: "doc"
        case .audio: "waveform"
        case .video: "film"
        case .links: "link"
        case .folders: "folder"
        }
    }

    var objectKinds: Set<ObjectKind> {
        switch self {
        case .images: [.image, .screenshot]
        case .documents: [.pdf, .file]
        case .audio: [.audio]
        case .video: [.video]
        case .links: [.link]
        case .folders: []
        }
    }

    var emptyTitle: LocalizedStringResource {
        switch self {
        case .images: "No Images"
        case .documents: "No Documents"
        case .audio: "No Audio"
        case .video: "No Video"
        case .links: "No Links"
        case .folders: "No Folders"
        }
    }
}

/// The app's view state over a library.
///
/// Every read goes through `LibraryService` and arrives as a `Sendable`
/// snapshot; the UI never holds a SwiftData model and never queries the store
/// directly. That is what keeps the privacy broker underneath the interface
/// rather than beside it.
@MainActor
@Observable
final class LibraryModel {
    static let libraryDidChange = Notification.Name("Nook.libraryDidChange")

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

    var previewedObjectID: ObjectID? { didSet { previewDidChange(from: oldValue) } }
    var isInspectorPresented = false

    /// Shows or hides the metadata panel.
    ///
    /// Every route to Get Info goes through here — the toolbar button, the menu
    /// bar, the context menu, the preview — so the panel has one anchor to
    /// appear at whichever way it was asked for. It is a popover on the canvas
    /// toolbar's Info button at regular width, and a sheet on iPhone.
    func setInspector(_ presented: Bool) {
        isInspectorPresented = presented
    }

    func toggleInspector() {
        setInspector(!isInspectorPresented)
    }

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
    var isAddURLPresented = false
    /// iOS only in practice, but held here for the same reason the file
    /// importer is: the window raises it, so both Home and the canvas can ask
    /// for it without either owning it.
    var isPhotosPickerPresented = false
    /// iOS only: raises the system camera for "Take Photo".
    var isCameraPresented = false
    /// iOS only: raises VisionKit's document camera for "Scan Document".
    var isDocumentScannerPresented = false
    var isGlobalSearchPresented = false
    var isSettingsPresented = false
    /// Raised while the user picks a folder to export originals into.
    var isExportPickerPresented = false
    /// Home is a destination rather than a query, so it sits beside the scope
    /// rather than inside it.
    var isShowingHome = true
    var namingPrompt: NamingPrompt?
    /// The folder, collection or tag whose appearance is being edited. Held
    /// here for the same reason `namingPrompt` is: the sidebar and the canvas
    /// both raise it, and only one of them can own the sheet.
    var editingAppearance: AppearanceTarget?
    var searchFieldFocusRequests = 0

    /// The most recent explicit creation/import batch. Gallery and sidebar
    /// views use its stable identifiers to animate only genuinely new items.
    private(set) var arrival: LibraryArrival?
    private var arrivalRevision = 0
    private var clearArrivalTask: Task<Void, Never>?

    /// Changes only for an explicit library mutation or preference-driven
    /// reorder, never for navigation, search, initial loading, or sync refresh.
    private(set) var reflowRevision = 0
    private(set) var sidebarReflowRevision = 0
    private var isReflowPending = false

    /// The scope pill in the search field. Removing it widens the same query
    /// to the whole library; it is not a separate search.
    var searchTokens: [SearchScopeToken] = []

    /// The quick filter applied inside the current location. It intentionally
    /// survives navigation but is never written to settings or the store.
    private(set) var contentFilter: LibraryContentFilter?

    /// Which filter pills are worth showing for the current location.
    ///
    /// A pill for a type with nothing behind it just adds dead taps, so this
    /// is recomputed on every refresh from what's actually here. The active
    /// filter is kept in even at zero results, since that's the only way to
    /// switch it back off.
    private(set) var availableContentFilters: Set<LibraryContentFilter> = []

    /// The stages the latest change to `availableContentFilters` needs.
    private(set) var contentFilterChange: MotionChoreography = .none

    // MARK: Contents

    private(set) var contents: LocationContents = .empty

    /// Where `contents` was fetched for. It trails `destination` by one
    /// query: the canvas keeps showing the last place until the next one has
    /// actually arrived, and this is what tells it the moment that happens —
    /// so leaving for somewhere else reads as one place giving way to
    /// another, while a search, a filter or a deletion within the same place
    /// reads as items coming and going.
    private(set) var contentsDestination: LibraryDestination?

    /// Which stages the latest change to `contents` needs — whether anything
    /// left, whether what stayed moved, whether anything arrived — so the
    /// canvas can hold each stage back exactly as long as the ones before it
    /// and no longer.
    private(set) var contentsChange: MotionChoreography = .none

    /// The same, for the places the sidebar names.
    private(set) var sidebarChange: MotionChoreography = .none
    private(set) var breadcrumbs: [FolderSnapshot] = []
    private(set) var folderTree: [FolderNode] = []
    private(set) var collections: [CollectionSnapshot] = []
    private(set) var tags: [TagSnapshot] = []
    private(set) var counts: [ScopeCountKey: Int] = [:]
    /// The media types the library currently holds something of.
    private(set) var populatedKinds: Set<ObjectKind> = []

    /// Media types the sidebar shows a row for. The current scope remains
    /// visible if its last item is deleted, so selection never disappears.
    var presentMediaKinds: Set<ObjectKind> {
        guard case .kind(let kind) = scope else { return populatedKinds }
        return populatedKinds.union([kind])
    }

    /// The media types the sidebar lists.
    ///
    /// A library with no video in it has no use for a Videos row: the media
    /// types are a way into what is there, not a catalogue of what could be.
    /// The kind currently open stays listed either way, so deleting the last
    /// image does not take the selected row out from under the selection.
    var mediaTypes: [ObjectKind] {
        ObjectKind.mediaTypes.filter(presentMediaKinds.contains)
    }

    // MARK: Transient state

    private(set) var importProgress: ImportProgress?
    var alert: LibraryAlert?
    var importFailure: ImportFailure?
    private(set) var toast: LibraryToast?
    private var toastRevision = 0
    @ObservationIgnored private var clearToastTask: Task<Void, Never>?

    // MARK: iCloud sync

    /// Active CloudKit event identifiers let overlapping import and export work
    /// present as one uninterrupted sync operation.
    private var activeCloudSyncEvents: Set<UUID> = []
    private(set) var isCloudSyncing = false
    private(set) var lastCloudSyncDate: Date?
    private(set) var cloudSyncError: String?

    /// The authenticated state every read is made under. Hidden and locked
    /// content stays out of reach until the authentication flow raises this,
    /// which only `LibraryModel+Privacy` does, and only after the device owner
    /// has said yes.
    var accessContext: AccessContext = .standard {
        didSet {
            contentsRefreshGeneration += 1
            folderPeeks = [:]
        }
    }

    private var searchTask: Task<Void, Never>?
    private var navigationRefreshTask: Task<Void, Never>?
    /// Scheduled when hidden items are revealed and cancelled when they re-hide.
    /// Lives here because Swift extensions in another file cannot add storage.
    var hiddenRevealTask: Task<Void, Never>?
    /// Kept injectable so the idle-lock behavior can be tested without making
    /// the privacy suite wait for a real 30-second timeout.
    @ObservationIgnored
    let hiddenRevealSleep: @Sendable (Duration) async throws -> Void

    // MARK: Presentation
    //
    // The arrangement on screen: a location's remembered settings if it has
    // any, otherwise the global preferences. View-mode changes made while a
    // location is following the global preferences become the app-wide mode;
    // explicitly remembered locations keep their own mode.

    private(set) var preferences: LocationViewPreferences = .systemDefault
    private(set) var isRememberingLocation = false
    private(set) var canRememberLocation = false

    var sort: ObjectSort { preferences.sort }
    var viewMode: LibraryViewMode { preferences.viewMode }
    var foldersFirst: Bool { preferences.foldersFirst }
    var masonryCaptionDisplay: MasonryCaptionDisplay { preferences.masonryCaptionDisplay }
    var showsMasonryTypeLabels: Bool { preferences.showsMasonryTypeLabels }
    // On iPhone, item size is decided by the adaptive grid rather than the
    // user, so this always reads as the neutral size regardless of whatever
    // scale a synced macOS preference carries. iPad has room for the size
    // slider in the view options popover, so it reads the real preference
    // like macOS does.
    #if os(iOS)
    var itemScale: Double {
        UIDevice.current.userInterfaceIdiom == .pad ? preferences.itemScale : 1
    }
    #else
    var itemScale: Double { preferences.itemScale }
    #endif

    /// Who vouches for the device owner before hidden or locked content moves.
    /// Injected so the app's tests can answer without a device.
    let authenticator: any LibraryAuthenticating

    init(library: Library,
         settings: AppSettings,
         authenticator: any LibraryAuthenticating = DeviceAuthenticator(),
         hiddenRevealSleep: @escaping @Sendable (Duration) async throws -> Void = {
             try await Task.sleep(for: $0)
         }) {
        self.library = library
        self.settings = settings
        self.authenticator = authenticator
        self.hiddenRevealSleep = hiddenRevealSleep
        self.preferences = settings.defaultPreferences
        self.lastCloudSyncDate = UserDefaults.standard.object(
            forKey: Self.lastCloudSyncDefaultsKey
        ) as? Date
    }

    private var service: LibraryService { library.service }

    // MARK: Refresh

    private func publishPendingReflow() {
        guard isReflowPending else { return }
        isReflowPending = false
        reflowRevision += 1
    }

    func refreshAll() async {
        await refreshSidebar()
        await loadPreferences()
        await refreshContents()
    }

    func cloudSyncStarted(id: UUID) {
        activeCloudSyncEvents.insert(id)
        isCloudSyncing = true
        cloudSyncError = nil
    }

    func cloudSyncFinished(
        id: UUID,
        succeeded: Bool,
        error: String?,
        importedChanges: Bool,
        at date: Date
    ) async {
        activeCloudSyncEvents.remove(id)
        isCloudSyncing = !activeCloudSyncEvents.isEmpty

        if succeeded {
            cloudSyncError = nil
            lastCloudSyncDate = date
            UserDefaults.standard.set(date, forKey: Self.lastCloudSyncDefaultsKey)
            if importedChanges {
                await refreshAll()
                extractPendingContent()
                fetchPendingLinkMetadata()
            }
        } else {
            cloudSyncError = error ?? "iCloud couldn't complete the sync."
        }
    }

    private static let lastCloudSyncDefaultsKey = "Nook.lastSuccessfulCloudSync"

    // MARK: Presentation

    /// Loads whatever this location has been asked to remember, falling back to
    /// the global default so an unremembered location never inherits the last
    /// one's arrangement.
    func loadPreferences() async {
        navigationRefreshTask?.cancel()
        navigationRefreshTask = nil
        await loadCurrentPreferences()
    }

    /// Reads the current destination's arrangement without cancelling the
    /// navigation task that asked for it. Public callers cancel that task
    /// first, so an explicit toolbar action cannot be overwritten by a slower
    /// load that navigation started a moment earlier.
    private func loadCurrentPreferences() async {
        // Hidden closes behind you: navigating anywhere that does not belong
        // to it puts everything back out of reach before that place's own
        // arrangement and contents are loaded, so coming back always asks
        // again. Every navigation path — the scheduled refresh and the
        // callers that await this directly — funnels through here.
        await closeHidden()
        await closeLockedFolders()

        // Home is one fixed place rather than a row in the library, so what it
        // remembers is kept beside the global default rather than on a folder.
        if isShowingHome {
            canRememberLocation = true
            preferences = settings.homePreferences ?? settings.defaultPreferences
            isRememberingLocation = settings.homePreferences != nil
            return
        }
        let canRemember = await service.canRememberPreferences(for: scope)
        guard !Task.isCancelled else { return }
        let remembered = await service.rememberedPreferences(for: scope)
        guard !Task.isCancelled else { return }
        canRememberLocation = canRemember
        if let remembered {
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
        if !isRememberingLocation {
            settings.defaultPreferences.viewMode = mode
        }
        await apply(updated)
    }

    func setMasonryCaptionDisplay(_ display: MasonryCaptionDisplay) async {
        guard display != preferences.masonryCaptionDisplay else { return }
        isReflowPending = true
        var updated = preferences
        updated.masonryCaptionDisplay = display
        if !isRememberingLocation {
            settings.defaultPreferences.masonryCaptionDisplay = display
        }
        await apply(updated)
    }

    func setShowsMasonryTypeLabels(_ showsTypeLabels: Bool) async {
        guard showsTypeLabels != preferences.showsMasonryTypeLabels else { return }
        var updated = preferences
        updated.showsMasonryTypeLabels = showsTypeLabels
        if !isRememberingLocation {
            settings.defaultPreferences.showsMasonryTypeLabels = showsTypeLabels
        }
        await apply(updated)
    }

    func setSort(_ sort: ObjectSort) async {
        isReflowPending = true
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
    ///
    /// A location following the global default writes the size into that
    /// default, the way changing the view mode does — otherwise the next
    /// change to the default (switching views, say) reloads it and the size
    /// snaps back to whatever it was before the drag.
    func commitItemScale() async {
        guard isRememberingLocation else {
            if settings.defaultPreferences.itemScale != preferences.itemScale {
                settings.defaultPreferences.itemScale = preferences.itemScale
            }
            return
        }
        // Home keeps its arrangement beside the global default rather than on
        // a folder, so that is where its size is written too.
        if isShowingHome {
            settings.homePreferences = preferences
            return
        }
        try? await service.rememberPreferences(preferences, for: scope)
    }

    func setFoldersFirst(_ foldersFirst: Bool) async {
        isReflowPending = true
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
        if isShowingHome {
            settings.homePreferences = isRemembering ? preferences : nil
            return
        }
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
        if isShowingHome {
            if isRememberingLocation { settings.homePreferences = updated }
            await refreshContents()
            return
        }
        if isRememberingLocation {
            try? await service.rememberPreferences(updated, for: scope)
        }
        await refreshContents()
    }

    func refreshSidebar() async {
        let access = accessContext
        async let collections = service.collections(in: access)
        async let tags = service.tags(in: access)
        let folderTree = await loadFolderTree(under: nil)
        let loadedCollections = await collections
        let loadedTags = await tags
        let previousPlaces = sidebarPlaceIDs
        self.folderTree = folderTree
        self.collections = loadedCollections
        self.tags = loadedTags
        sidebarChange = MotionChoreography(from: previousPlaces, to: sidebarPlaceIDs)
        if isReflowPending { sidebarReflowRevision += 1 }
        await refreshCounts()
        pruneHistory()
    }

    /// Where the canvas is currently reading from.
    ///
    /// While searching, the scope pill decides — removing it expands the query
    /// to the whole library without changing what is selected in the sidebar.
    var effectiveScope: LibraryScope {
        guard !searchText.isEmpty else { return isShowingHome ? .allObjects : scope }
        return searchTokens.first?.scope ?? .allObjects
    }

    private var contentsRefreshGeneration = 0
    private(set) var folderPeeks: [FolderID: [ObjectSnapshot]] = [:]

    func refreshContents() async {
        navigationRefreshTask?.cancel()
        navigationRefreshTask = nil
        await performRefreshContents()
    }

    private func performRefreshContents() async {
        contentsRefreshGeneration += 1
        let generation = contentsRefreshGeneration
        let access = accessContext
        let filter = contentFilter

        // Fetched unfiltered so the pill bar can tell which kinds actually
        // sit at this location — the kind filter below is applied locally.
        let query = ObjectQuery(scope: effectiveScope, searchText: searchText, sort: sort)
        let unfilteredObjects = await service.objects(matching: query, in: access)

        let objects: [ObjectSnapshot]
        if let filter, filter != .folders {
            objects = unfilteredObjects.filter { filter.objectKinds.contains($0.kind) }
        } else if filter == .folders {
            objects = []
        } else {
            objects = unfilteredObjects
        }

        let locationFolders: [FolderSnapshot]
        if isShowingHome {
            locationFolders = await service.rootFolders(in: access)
            breadcrumbs = []
        } else if case .folder(let id) = effectiveScope {
            locationFolders = await service.subfolders(of: id, in: access)
            breadcrumbs = await service.folderPath(to: id, in: access)
        } else if effectiveScope == .hidden {
            // Hidden holds folders as well as objects, which is what makes it
            // a place rather than a list of loose things.
            locationFolders = await service.hiddenFolders(in: access)
            breadcrumbs = []
        } else {
            locationFolders = []
            breadcrumbs = []
        }

        let searchedFolders: [FolderSnapshot]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchedFolders = locationFolders
        } else {
            searchedFolders = locationFolders.filter { folderMatchesSearch($0, text: searchText) }
        }

        let folders: [FolderSnapshot] = (filter == nil || filter == .folders) ? searchedFolders : []

        var peeks: [FolderID: [ObjectSnapshot]] = [:]
        for folder in folders where folder.visibility == .full {
            peeks[folder.id] = await service.objects(
                matching: ObjectQuery(scope: .folder(folder.id), limit: 3), in: access
            )
        }
        guard generation == contentsRefreshGeneration, !Task.isCancelled else { return }
        let arrived = LocationContents(folders: folders, objects: objects)
        // Worked out against what the canvas was showing, when that was the
        // same place. A change of place animates as a whole rather than item
        // by item, so it has no stages of its own.
        contentsChange = contentsDestination == destination
            ? MotionChoreography(from: contents.itemIDs, to: arrived.itemIDs)
            : .none
        folderPeeks = peeks
        contents = arrived
        contentsDestination = destination
        if pendingPage?.page.destination == destination { commitPendingPage() }

        let presentKinds = Set(unfilteredObjects.map(\.kind))
        var available = Set(LibraryContentFilter.allCases.filter { candidate in
            candidate != .folders && !candidate.objectKinds.isDisjoint(with: presentKinds)
        })
        if !searchedFolders.isEmpty { available.insert(.folders) }
        // Keeps the active pill on screen even if it stops matching anything
        // (e.g. the last image in a folder gets moved out) — it's still the
        // only way to switch the filter back off.
        if let filter { available.insert(filter) }
        contentFilterChange = MotionChoreography(
            from: LibraryContentFilter.allCases.filter(availableContentFilters.contains),
            to: LibraryContentFilter.allCases.filter(available.contains)
        )
        availableContentFilters = available

        publishPendingReflow()
        // A deletion, a move or an arriving import can take whatever the
        // cursor was resting on out from under it.
        let present = Set(canvasItems.map(\.itemID))
        if let current = cursor, !present.contains(current) { cursor = nil }
        pruneSelection()
    }

    /// Folder queries are intentionally local to the location being shown:
    /// the storage query searches objects, while this is the small sibling
    /// list already fetched for the current folder. Every typed term must
    /// occur in the name, matching the conjunctive object-search behavior.
    private func folderMatchesSearch(_ folder: FolderSnapshot, text: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let foldedName = folder.name.folding(options: options, locale: .current)
        let terms = text
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).folding(options: options, locale: .current) }
        return terms.allSatisfy(foldedName.contains)
    }

    /// Drops any selection that no longer names a visible object.
    private func pruneSelection() {
        let objects = Set(contents.objects.map(\.id))
        selection = selection.filter { objects.contains($0) }
        if let anchor = selectionAnchor, !selection.contains(anchor) { selectionAnchor = nil }
    }

    private func refreshCounts() async {
        let access = accessContext
        var updated: [ScopeCountKey: Int] = [:]
        for key in ScopeCountKey.allCases {
            updated[key] = await service.objectCount(in: key.scope, access: access)
        }
        counts = updated

        var populated: Set<ObjectKind> = []
        for kind in ObjectKind.mediaTypes {
            if await service.objectCount(in: .kind(kind), access: access) > 0 {
                populated.insert(kind)
            }
        }
        populatedKinds = populated
    }

    private func onScopeChanged(from previous: LibraryScope) {
        guard previous != scope else { return }
        // Opening a folder on the canvas sets the scope directly, and that is
        // a step in its own right. A step made through `navigate(to:)`, or by
        // going back, is refused by `pushHistory` while it is being applied.
        pushHistory(.scope(previous))
        if !isTraversingHistory { pushPage() }
        selection = []
        selectionAnchor = nil
        cursor = nil
        searchText = ""
        scheduleNavigationRefresh()
    }

    private func scheduleNavigationRefresh() {
        navigationRefreshTask?.cancel()
        navigationRefreshTask = Task { [weak self] in
            guard let self else { return }
            await loadCurrentPreferences()
            guard !Task.isCancelled else { return }
            await refreshContentsFromNavigation()
        }
    }

    private func refreshContentsFromNavigation() async {
        await performRefreshContents()
    }

    /// Search runs after a short pause so typing does not re-query per keystroke.
    private func scheduleSearchRefresh() {
        // Typing in a location scopes the search there, shown as a removable
        // pill. Clearing the field puts the pill away again.
        if searchText.isEmpty {
            searchTokens = []
        } else if !isShowingHome, searchTokens.isEmpty,
                  let token = SearchScopeToken(scope: scope, model: self) {
            searchTokens = [token]
        }

        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await refreshContents()
        }
    }

    /// Selecting the active category again removes it. Refreshing changes
    /// only what the current destination displays; navigation state and saved
    /// location preferences are deliberately untouched.
    func toggleContentFilter(_ filter: LibraryContentFilter) async {
        contentFilter = contentFilter == filter ? nil : filter
        await refreshContents()
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
    ///
    /// `startingPageStack` is for the sidebar: a place picked there replaces
    /// the page stack rather than being pushed onto it.
    func navigate(to destination: LibraryDestination, startingPageStack: Bool = false) {
        defer { if startingPageStack { restartPages() } }
        let previous = self.destination
        guard previous != destination else {
            // Re-activating the current place means returning to its canvas,
            // even when a preview is sitting in front of it.
            previewedObjectID = nil
            return
        }
        pushHistory(previous)
        apply(destination)
        if !startingPageStack { pushPage() }
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
        popPage()
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(destination)
        apply(target)
        pushPage()
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
            deselectAll()
            searchText = ""
            // Arriving at a scope loads its arrangement through
            // `onScopeChanged`; arriving at Home changes no scope, so it asks
            // for its own here.
            scheduleNavigationRefresh()
        case .scope(let scope):
            isShowingHome = false
            searchText = ""
            // Leaving Home for the place the canvas was already pointing at
            // changes no scope, so `onScopeChanged` never fires and nothing
            // else would load that place's arrangement back.
            let wasAlreadyThere = self.scope == scope
            self.scope = scope
            if wasAlreadyThere { scheduleNavigationRefresh() }
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

    // MARK: Pages
    //
    // On iOS and iPadOS each step Back can undo is a page of its own on a
    // navigation stack, so the system back button and the edge swipe retrace
    // the same path Back does instead of leaving the canvas altogether. A
    // preview is a page too, and only ever the top one: going anywhere from
    // it closes it first, the same way history treats it.
    //
    // The stack starts over wherever the sidebar or the iPhone's Library list
    // sends the canvas, and grows with every step taken from there. Empty
    // means nothing is pushed — on iPhone, the Library list is showing; on
    // the Mac, always.

    private(set) var pages: [LibraryPage] = [] {
        didSet {
            let ids = Set(pages.map(\.id))
            pageStates = pageStates.filter { ids.contains($0.key) }
            pageScrollOffsets = pageScrollOffsets.filter { ids.contains($0.key) }
        }
    }

    /// What each covered page was showing when it was left, so going back to
    /// it puts that straight back on the canvas instead of loading the place
    /// again from nothing. The refresh that follows then only animates what
    /// has actually changed since.
    @ObservationIgnored private var pageStates: [LibraryPage.ID: PageState] = [:]

    /// How far down each page had been scrolled.
    @ObservationIgnored private var pageScrollOffsets: [LibraryPage.ID: CGFloat] = [:]

    private struct PageState {
        let destination: LibraryDestination
        let contents: LocationContents
        let folderPeeks: [FolderID: [ObjectSnapshot]]
        let breadcrumbs: [FolderSnapshot]
        let availableContentFilters: Set<LibraryContentFilter>
        let preferences: LocationViewPreferences
        let canRememberLocation: Bool
        let isRememberingLocation: Bool
    }

    func rememberScrollOffset(_ offset: CGFloat, for page: LibraryPage.ID) {
        pageScrollOffsets[page] = offset
    }

    func scrollOffset(for page: LibraryPage.ID) -> CGFloat? {
        pageScrollOffsets[page]
    }

    /// Raised while the stack is telling the model where it has landed, so
    /// the model's own changes on the way there are not taken as new steps.
    private var isApplyingPages = false

    /// The page the live canvas belongs to: the top one, or the one beneath
    /// a preview. Every other page is drawn as it was left.
    var livePageID: LibraryPage.ID? {
        pages.last { $0.previewedObjectID == nil }?.id
    }

    /// Starts a stack at wherever the canvas is now — the iPad's detail
    /// column, which always has a page to show.
    func startPagesIfNeeded() {
        guard pages.isEmpty else { return }
        pages = [LibraryPage(destination: destination, previewedObjectID: previewedObjectID)]
    }

    /// Pushes a page the iPhone's Library list asked for, before the canvas
    /// has got there, so the push is not held up by loading or Face ID.
    ///
    /// `waitingForContents` holds the push back until the place has loaded
    /// instead, so the page slides in full rather than filling in on arrival.
    func beginPages(with page: LibraryPage, waitingForContents: Bool = false) {
        guard waitingForContents, contentsDestination != page.destination else {
            discardPendingPage()
            pages = [page]
            return
        }
        holdBack(page, replacingStack: true)
    }

    // A step deeper waits for its place to load before its page goes up —
    // a local query, well under the time a push takes — so the page arrives
    // with its contents rather than sliding in empty and filling in after.
    // Should loading take longer than that, the page goes up regardless.

    @ObservationIgnored private var pendingPage: (page: LibraryPage, replacingStack: Bool)?
    @ObservationIgnored private var pendingPageTimeout: Task<Void, Never>?

    private func holdBack(_ page: LibraryPage, replacingStack: Bool) {
        pendingPage = (page, replacingStack)
        pendingPageTimeout?.cancel()
        pendingPageTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.commitPendingPage()
        }
    }

    /// Puts up the page that was waiting, if the canvas is still headed there.
    private func commitPendingPage() {
        guard let pending = pendingPage else { return }
        discardPendingPage()
        guard pending.page.destination == destination else { return }
        if pending.replacingStack {
            pages = [pending.page]
        } else if pages.last?.destination != destination {
            pages.append(pending.page)
        }
    }

    /// Returns whether there was a page waiting.
    @discardableResult
    private func discardPendingPage() -> Bool {
        pendingPageTimeout?.cancel()
        pendingPageTimeout = nil
        defer { pendingPage = nil }
        return pendingPage != nil
    }

    /// The system popped pages: the back button, the edge swipe, or a pick
    /// from the back button's menu. The model follows to wherever it landed.
    func popPages(to remaining: [LibraryPage]) {
        discardPendingPage()
        guard remaining.count < pages.count else { return }
        var walking = pages
        while walking.count > remaining.count {
            let leaving = walking.removeLast()
            // Leaving a preview is not a change of place.
            guard leaving.previewedObjectID == nil, let under = walking.last else { continue }
            if backStack.last == under.destination { backStack.removeLast() }
            forwardStack.append(leaving.destination)
        }

        isApplyingPages = true
        defer { isApplyingPages = false }
        pages = remaining
        guard let landing = remaining.last else {
            previewedObjectID = nil
            return
        }
        if landing.destination != destination {
            apply(landing.destination)
            restorePageState()
        }
        previewedObjectID = landing.previewedObjectID
    }

    /// Takes the canvas to a page already pushed for it: a row in the
    /// iPhone's Library list, or the start page.
    func openPage(_ destination: LibraryDestination) async {
        switch destination {
        case .home:
            navigate(to: .home)
        case .scope(.hidden):
            await openHidden()
        case .scope(.folder(let id)):
            // A locked folder authenticates before the canvas lands on it,
            // rather than navigating straight to the door.
            await openFolder(id)
        case .scope(let scope):
            navigate(to: .scope(scope))
        }
        // Declining Face ID leaves the canvas where it was, so the page that
        // went up for it has nothing to show.
        guard self.destination == destination else {
            popPages(to: [])
            return
        }
        await loadPreferences()
        await refreshContents()
    }

    /// Where the iPhone opens and Home returns to, or nil for the Library
    /// list. A start folder that has since been deleted falls back to All.
    var startDestination: LibraryDestination? {
        if case .folder(let id) = settings.startPage,
           !allFolders.contains(where: { $0.folder.id == id }) {
            return .home
        }
        return settings.startPage.destination
    }

    /// Whether the start page has been put up since launch, so a return to
    /// the compact layout later does not push it a second time.
    private var hasShownStartPage = false

    /// Puts the start page up over the Library list as the app opens, in
    /// place rather than sliding in. The page goes up at once; the returned
    /// task is the canvas catching up with it.
    @discardableResult
    func showStartPageAtLaunch() -> Task<Void, Never>? {
        guard !hasShownStartPage else { return nil }
        hasShownStartPage = true
        guard pages.isEmpty, let start = startDestination else { return nil }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            beginPages(with: LibraryPage(destination: start))
        }
        return Task { await openPage(start) }
    }

    /// Home: back to the start page, or to the Library list when that is
    /// the start page.
    @discardableResult
    func showStartPage() -> Task<Void, Never>? {
        guard let start = startDestination else {
            popPages(to: [])
            return nil
        }
        // Already beneath everything pushed since: pop back to it.
        if let first = pages.first, first.destination == start, first.previewedObjectID == nil {
            popPages(to: [first])
            return nil
        }
        popPages(to: [])
        beginPages(with: LibraryPage(destination: start))
        return Task { await openPage(start) }
    }

    /// A place picked in the sidebar is a new root, not a step deeper, and it
    /// replaces the column's contents in place rather than sliding over them.
    private func restartPages() {
        discardPendingPage()
        guard !pages.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pages = [LibraryPage(destination: destination)]
        }
    }

    private func pushPage() {
        guard !pages.isEmpty, !isApplyingPages,
              pages.last?.destination != destination
        else { return }
        // The canvas has not loaded the new place yet, so what it holds is
        // still the page being covered.
        if let covered = pages.last, covered.previewedObjectID == nil,
           contentsDestination == covered.destination {
            pageStates[covered.id] = PageState(
                destination: covered.destination,
                contents: contents,
                folderPeeks: folderPeeks,
                breadcrumbs: breadcrumbs,
                availableContentFilters: availableContentFilters,
                preferences: preferences,
                canRememberLocation: canRememberLocation,
                isRememberingLocation: isRememberingLocation
            )
        }
        holdBack(LibraryPage(destination: destination), replacingStack: false)
    }

    /// Puts back what a page was showing when it was covered.
    private func restorePageState() {
        guard let page = pages.last, page.destination == destination,
              let state = pageStates[page.id], state.destination == destination
        else { return }
        contentsChange = .none
        contentFilterChange = .none
        contents = state.contents
        folderPeeks = state.folderPeeks
        breadcrumbs = state.breadcrumbs
        availableContentFilters = state.availableContentFilters
        preferences = state.preferences
        canRememberLocation = state.canRememberLocation
        isRememberingLocation = state.isRememberingLocation
        contentsDestination = destination
    }

    /// Back was asked for from the keyboard or a menu rather than by the
    /// stack itself.
    private func popPage() {
        guard !pages.isEmpty, !isApplyingPages else { return }
        // The step being undone never got as far as its own page.
        if discardPendingPage() {
            restorePageState()
            return
        }
        if pages.count > 1 { pages.removeLast() }
        // History reaches further back than the stack: stepping past its
        // first page makes wherever Back landed the new first page.
        if pages.last?.destination != destination {
            pages[pages.count - 1] = LibraryPage(destination: destination)
        }
        restorePageState()
    }

    private func previewDidChange(from previous: ObjectID?) {
        guard !pages.isEmpty, !isApplyingPages, previous != previewedObjectID else { return }
        commitPendingPage()
        let top = pages.count - 1
        switch (pages[top].previewedObjectID, previewedObjectID) {
        case (nil, let opened?):
            pages.append(LibraryPage(destination: destination, previewedObjectID: opened))
        case (_?, let stepped?):
            // Stepping to the next item stays on the same page.
            pages[top].previewedObjectID = stepped
        case (_?, nil):
            pages.removeLast()
        case (nil, nil):
            break
        }
    }

    /// Takes pages for places that no longer exist out from under the one on
    /// screen, and closes up two copies of one place left side by side.
    private func prunePages(keeping survives: (LibraryDestination) -> Bool) {
        guard pages.count > 1 else { return }
        var kept: [LibraryPage] = []
        for (index, page) in pages.enumerated() {
            let isTop = index == pages.count - 1
            guard isTop || survives(page.destination) else { continue }
            if !isTop, page.previewedObjectID == nil,
               kept.last?.destination == page.destination { continue }
            if isTop, page.previewedObjectID == nil,
               kept.last?.destination == page.destination, kept.last?.previewedObjectID == nil {
                kept[kept.count - 1] = page
                continue
            }
            kept.append(page)
        }
        if kept != pages { pages = kept }
    }

    /// What a place is called, from what the sidebar already knows, so a page
    /// can be titled before the canvas has loaded it.
    func title(for destination: LibraryDestination) -> String {
        guard case .scope(let scope) = destination else { return "All" }
        switch scope {
        case .folder(let id):
            if let crumb = breadcrumbs.last, crumb.id == id { return crumb.name }
            return allFolders.first { $0.folder.id == id }?.folder.name ?? "Folder"
        case .collection(let id): return collections.first { $0.id == id }?.name ?? "Collection"
        case .tag(let id): return tags.first { $0.id == id }?.name ?? "Tag"
        default: return scope.displayName
        }
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
            // A media type the library no longer holds anything of has left
            // the sidebar, so Back should not walk into it either.
            case .kind(let kind): return populatedKinds.contains(kind)
            // Back never walks into Hidden: it closed when the user left, and
            // a step through history is not somewhere to be asked for a
            // fingerprint.
            case .hidden: return isShowingHiddenContent
            default: return true
            }
        }

        backStack.removeAll { !survives($0) }
        forwardStack.removeAll { !survives($0) }
        prunePages(keeping: survives)
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

    var canSelectAll: Bool { !isTypingText && !visibleObjects.isEmpty }

    /// Selects what is on screen. Folders are places rather than things, so
    /// they are not part of a selection the batch actions can act on.
    func selectAll() {
        selection = Set(contents.objects.map(\.id))
    }

    func deselectAll() {
        selection = []
        selectionAnchor = nil
    }

    // MARK: Import

    /// Brings items in, and hands back what arrived so a caller that asked for
    /// somewhere in particular — a drop on a collection, on a tag — can put
    /// them there.
    ///
    /// `destination` is the folder they land in. Left out, they land where the
    /// user is: Home is not a place things go into, so importing from it puts
    /// them where anything imported without choosing a folder goes.
    @discardableResult
    func importItems(_ items: [ImportItem], into destination: ImportDestination? = nil) async -> [ObjectID] {
        guard !items.isEmpty else { return [] }
        let destination = destination ?? (isShowingHome ? .root : ImportDestination(scope: scope))

        let report = await service.importItems(items, into: destination) { [weak self] progress in
            Task { @MainActor in self?.importProgress = progress.isFinished ? nil : progress }
        }
        importProgress = nil
        announceArrival(objects: report.importedIDs)
        NotificationCenter.default.post(name: Self.libraryDidChange, object: nil)
        await refreshAll()
        extractPendingContent()
        fetchPendingLinkMetadata()

        if !report.importedIDs.isEmpty {
            let count = report.importedIDs.count
            let message: LocalizedStringResource = count == 1
                ? "Added one item to Nook"
                : "Added \(count) items to Nook"
            showToast(message, systemImage: "plus.circle.fill", tint: .green)
        }

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
        return report.importedIDs
    }

    func importFiles(at urls: [URL], into destination: ImportDestination? = nil) async {
        await importItems(urls.map { ImportItem.file(url: $0) }, into: destination)
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

    /// A photo from the system camera. The camera view already encodes it to
    /// PNG, so this stays free of UIKit types.
    func importCapturedPhoto(_ data: Data) async {
        await importItems([.data(data, contentType: .png, suggestedName: "Photo.png")])
    }

    /// The PDF VisionKit's document camera produced from one or more scanned
    /// pages.
    func importScannedDocument(_ data: Data) async {
        await importItems([.data(data, contentType: .pdf, suggestedName: "Scan.pdf")])
    }

    /// Continuity Camera hands back raw bytes with no content type attached,
    /// so this sniffs the format the same way `PasteImporter` does for a
    /// pasted image.
    func importContinuityCameraCapture(_ data: Data) async {
        let contentType: UTType
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            contentType = .jpeg
        } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            contentType = .png
        } else if data.starts(with: Array("%PDF".utf8)) {
            contentType = .pdf
        } else {
            contentType = .jpeg
        }
        let name = "Continuity Camera.\(contentType.preferredFilenameExtension ?? "dat")"
        await importItems([.data(data, contentType: contentType, suggestedName: name)])
    }

    // MARK: External navigation

    /// Acts on a request left by an intent — or later a share extension or a
    /// Spotlight result — that may have arrived before any window existed.
    func handle(_ request: AppNavigator.Request) async {
        switch request {
        case .scope(.folder(let id)):
            // A locked folder authenticates before the canvas lands on it,
            // rather than navigating straight to the door.
            await openFolder(id)
            await loadPreferences()
            await refreshContents()

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
            // more than the folder ancestry it lives in would have allowed.
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

            // Links whose page title is already known but which are still shown
            // under the domain they came from are named first: that costs no
            // network and settles the oldest saves.
            var didChange = !((try? await service.renameLinksStillNamedAfterTheirURL()) ?? []).isEmpty

            let metadataPending = await service.linksAwaitingMetadata()
            let previewCandidates = await service.linksAdvertisingPreviewImage()
            let pending = metadataPending + previewCandidates.filter { !metadataPending.contains($0) }
            guard !pending.isEmpty else {
                if didChange {
                    NotificationCenter.default.post(name: Self.libraryDidChange, object: nil)
                    await refreshAll()
                }
                return
            }

            for id in pending {
                guard let object = await service.object(id, in: accessContext),
                      let url = object.sourceURL
                else { continue }

                let needsMetadata = object.linkPageTitle == nil
                let hasLocalPreview = await thumbnails.hasPreviewImage(for: id)
                let needsDimensions = object.aspectRatio == nil

                if needsDimensions, hasLocalPreview,
                   let dimensions = await thumbnails.cachedPreviewImageDimensions(for: id) {
                    try? await service.applyLinkPreviewDimensions(
                        width: dimensions.width,
                        height: dimensions.height,
                        to: id
                    )
                    didChange = true
                }

                guard needsMetadata || !hasLocalPreview else { continue }
                guard let result = await LinkMetadataFetcher.fetch(for: url) else { continue }

                // A preview-only rebuild must not replace good synced metadata
                // with nil values from a partial refetch.
                if needsMetadata {
                    try? await service.applyLinkMetadata(result.metadata, to: id)
                    didChange = true
                } else if needsDimensions,
                          let width = result.metadata.previewPixelWidth,
                          let height = result.metadata.previewPixelHeight {
                    try? await service.applyLinkPreviewDimensions(
                        width: width,
                        height: height,
                        to: id
                    )
                    didChange = true
                }
                if let imageData = result.previewImageData {
                    await thumbnails.storePreviewImage(imageData, for: id)
                    didChange = true
                    NotificationCenter.default.post(
                        name: .nookThumbnailDidChange,
                        object: id.uuid
                    )
                }
            }

            guard didChange else { return }
            NotificationCenter.default.post(name: Self.libraryDidChange, object: nil)
            await refreshAll()
        }
    }

    // MARK: Originals

    /// A local file URL for an object's original, when the bytes are already
    /// on this device. Returns nil for one whose original has not been
    /// downloaded, or that arrived with no blob descriptor at all — which is
    /// what an object still buried in a locked folder would carry, though
    /// such an object is excluded before it ever reaches a snapshot list.
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

        let exportedCount = objects.count - failures.count
        if exportedCount > 0 {
            let message: LocalizedStringResource = exportedCount == 1
                ? "Exported one item"
                : "Exported \(exportedCount) items"
            showToast(message, systemImage: "square.and.arrow.up.fill", tint: .blue)
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

    private func announceArrival(objects: [ObjectID] = [],
                                 folders: [FolderID] = [],
                                 collections: [CollectionID] = []) {
        guard !objects.isEmpty || !folders.isEmpty || !collections.isEmpty else { return }
        isReflowPending = true
        arrivalRevision += 1
        arrival = LibraryArrival(revision: arrivalRevision,
                                 destination: destination,
                                 objectIDs: objects,
                                 folderIDs: folders,
                                 collectionIDs: collections)

        clearArrivalTask?.cancel()
        clearArrivalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.arrival = nil
        }
    }

    func createFolder(
        named name: String,
        in parent: FolderID?,
        appearance: EntityAppearance = .system
    ) async {
        await perform(
            successToast: "Created folder “\(name)”",
            systemImage: "folder.badge.plus",
            tint: .green
        ) {
            let created = try await self.library.service.createFolder(
                named: name,
                in: parent,
                appearance: appearance
            )
            self.announceArrival(folders: [created.id])
        }
    }

    func rename(folder id: FolderID, to name: String) async {
        await perform(
            successToast: "Renamed folder to “\(name)”",
            systemImage: "pencil.circle.fill",
            tint: .blue
        ) {
            try await self.library.service.renameFolder(id, to: name)
        }
    }

    func moveFolder(_ id: FolderID, to parent: FolderID?) async {
        await perform(successToast: "Moved folder", systemImage: "folder.fill", tint: .blue) {
            try await self.library.service.moveFolder(id, to: parent)
        }
    }

    func deleteFolder(_ id: FolderID) async {
        if case .folder(id) = scope { scope = .inbox }
        await perform(successToast: "Deleted folder", systemImage: "trash.fill", tint: .red) {
            try await self.library.service.deleteFolder(id)
        }
    }

    func move(_ ids: [ObjectID], to destination: FolderID?) async {
        guard !ids.isEmpty else { return }
        let message: LocalizedStringResource = ids.count == 1
            ? "Moved item"
            : "Moved \(ids.count) items"
        await perform(successToast: message, systemImage: "folder.fill", tint: .blue) {
            try await self.library.service.moveObjects(ids, to: destination)
        }
    }

    func setFavorite(_ isFavorite: Bool, for ids: [ObjectID]) async {
        guard !ids.isEmpty else { return }
        let message: LocalizedStringResource
        if ids.count == 1 {
            message = isFavorite ? "Added to Favorites" : "Removed from Favorites"
        } else {
            message = isFavorite
                ? "Added \(ids.count) items to Favorites"
                : "Removed \(ids.count) items from Favorites"
        }
        await perform(
            successToast: message,
            systemImage: isFavorite ? "star.fill" : "star.slash",
            tint: isFavorite ? .yellow : .orange
        ) {
            try await self.library.service.setFavorite(isFavorite, for: ids)
        }
    }

    func delete(_ ids: [ObjectID]) async {
        guard !ids.isEmpty else { return }
        if let previewed = previewedObjectID, ids.contains(previewed) { previewedObjectID = nil }
        let message: LocalizedStringResource = ids.count == 1
            ? "Moved to Recently Deleted"
            : "Moved \(ids.count) items to Recently Deleted"
        await perform(successToast: message, systemImage: "trash.fill", tint: .red) {
            try await self.library.service.delete(ids)
        }
    }

    func restore(_ ids: [ObjectID]) async {
        guard !ids.isEmpty else { return }
        let message: LocalizedStringResource = ids.count == 1
            ? "Restored item"
            : "Restored \(ids.count) items"
        await perform(
            successToast: message,
            systemImage: "arrow.uturn.backward.circle.fill",
            tint: .green
        ) {
            try await self.library.service.restore(ids)
        }
    }

    func permanentlyDelete(_ ids: [ObjectID]) async {
        guard !ids.isEmpty else { return }
        let message: LocalizedStringResource = ids.count == 1
            ? "Deleted item permanently"
            : "Deleted \(ids.count) items permanently"
        await perform(successToast: message, systemImage: "trash.slash", tint: .red) {
            try await self.library.service.permanentlyDelete(ids)
        }
    }

    func update(_ id: ObjectID, title: String? = nil, notes: String? = nil) async {
        await perform(
            successToast: "Changes saved",
            systemImage: "checkmark.circle.fill",
            tint: .green
        ) {
            try await self.library.service.updateObject(id, title: title, notes: notes)
        }
    }

    // MARK: Collections

    func createCollection(
        named name: String,
        adding ids: [ObjectID] = [],
        appearance: EntityAppearance = .system
    ) async {
        await perform(
            successToast: "Created collection “\(name)”",
            systemImage: "rectangle.stack.badge.plus",
            tint: .purple
        ) {
            let created = try await self.library.service.createCollection(
                named: name,
                appearance: appearance
            )
            if !ids.isEmpty {
                try await self.library.service.addObjects(ids, toCollection: created.id)
            }
            self.announceArrival(collections: [created.id])
        }
    }

    func addToCollection(_ collection: CollectionID, objects ids: [ObjectID]) async {
        guard !ids.isEmpty else { return }
        let message: LocalizedStringResource = ids.count == 1
            ? "Added to collection"
            : "Added \(ids.count) items to collection"
        await perform(
            successToast: message,
            systemImage: "rectangle.stack.badge.plus",
            tint: .purple
        ) {
            try await self.library.service.addObjects(ids, toCollection: collection)
        }
    }

    /// Removes membership only — the objects stay exactly where they live.
    func removeFromCollection(_ collection: CollectionID, objects ids: [ObjectID]) async {
        guard !ids.isEmpty else { return }
        let message: LocalizedStringResource = ids.count == 1
            ? "Removed from collection"
            : "Removed \(ids.count) items from collection"
        await perform(successToast: message, systemImage: "minus.circle.fill", tint: .orange) {
            try await self.library.service.removeObjects(ids, fromCollection: collection)
        }
    }

    func renameCollection(_ id: CollectionID, to name: String) async {
        await perform(
            successToast: "Renamed collection to “\(name)”",
            systemImage: "pencil.circle.fill",
            tint: .purple
        ) {
            try await self.library.service.renameCollection(id, to: name)
        }
    }

    func deleteCollection(_ id: CollectionID) async {
        if case .collection(id) = scope { scope = .inbox }
        await perform(successToast: "Deleted collection", systemImage: "trash.fill", tint: .red) {
            try await self.library.service.deleteCollection(id)
        }
    }

    // MARK: Appearance

    func updateEntity(
        _ reference: LibraryReference,
        name: String,
        appearance: EntityAppearance
    ) async {
        await perform(
            successToast: "Changes saved",
            systemImage: "checkmark.circle.fill",
            tint: .green
        ) {
            switch reference {
            case .folder(let id):
                try await self.library.service.updateFolder(id, name: name, appearance: appearance)
            case .collection(let id):
                try await self.library.service.updateCollection(id, name: name, appearance: appearance)
            case .tag(let id):
                try await self.library.service.updateTag(id, name: name, appearance: appearance)
            case .object:
                break
            }
        }
    }

    func setAppearance(_ appearance: EntityAppearance, for reference: LibraryReference) async {
        await perform(
            successToast: "Appearance updated",
            systemImage: "paintpalette.fill",
            tint: .purple
        ) {
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

    func createTag(
        named name: String,
        adding ids: [ObjectID] = [],
        appearance: EntityAppearance = .system
    ) async {
        await perform(
            successToast: "Created tag “\(name)”",
            systemImage: "tag.fill",
            tint: .purple
        ) {
            let created = try await self.library.service.createTag(named: name, appearance: appearance)
            if !ids.isEmpty {
                try await self.library.service.addTag(named: created.name, to: ids)
            }
        }
    }

    func renameTag(_ id: TagID, to name: String) async {
        await perform(
            successToast: "Renamed tag to “\(name)”",
            systemImage: "pencil.circle.fill",
            tint: .purple
        ) {
            try await self.library.service.renameTag(id, to: name)
        }
    }

    func deleteTag(_ id: TagID) async {
        if case .tag(id) = scope { scope = .inbox }
        await perform(successToast: "Deleted tag", systemImage: "trash.fill", tint: .red) {
            try await self.library.service.deleteTag(id)
        }
    }

    func addTag(_ name: String, to ids: [ObjectID]) async {
        guard !ids.isEmpty else { return }
        let message: LocalizedStringResource = ids.count == 1
            ? "Tagged with “\(name)”"
            : "Tagged \(ids.count) items with “\(name)”"
        await perform(successToast: message, systemImage: "tag.fill", tint: .purple) {
            try await self.library.service.addTag(named: name, to: ids)
        }
    }

    func removeTag(_ id: TagID, from ids: [ObjectID]) async {
        guard !ids.isEmpty else { return }
        let message: LocalizedStringResource = ids.count == 1
            ? "Removed tag"
            : "Removed tag from \(ids.count) items"
        await perform(successToast: message, systemImage: "minus.circle.fill", tint: .orange) {
            try await self.library.service.removeTag(id, from: ids)
        }
    }

    func perform(
        successToast: LocalizedStringResource? = nil,
        systemImage: String = "checkmark.circle.fill",
        tint: LibraryToastTint = .green,
        _ work: @escaping () async throws -> Void
    ) async {
        isReflowPending = true
        do {
            try await work()
            NotificationCenter.default.post(name: Self.libraryDidChange, object: nil)
            await refreshAll()
            if let successToast {
                showToast(successToast, systemImage: systemImage, tint: tint)
            }
        } catch {
            isReflowPending = false
            alert = LibraryAlert(title: "Something went wrong", message: error.localizedDescription)
        }
    }

    private func showToast(
        _ message: LocalizedStringResource,
        systemImage: String,
        tint: LibraryToastTint
    ) {
        toastRevision += 1
        let revision = toastRevision
        toast = LibraryToast(
            id: revision,
            message: message,
            systemImage: systemImage,
            tint: tint
        )

        clearToastTask?.cancel()
        clearToastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, self?.toast?.id == revision else { return }
            self?.toast = nil
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
        case .dateCreated, .kind, .size:
            return folders + objects
        }
    }

    /// The objects the current destination is showing, in reading order.
    ///
    /// Home is several queries at once, and an object recently imported and
    /// still unsorted is in both Inbox and Recent. It is listed once, where it
    /// first reads, because everything that asks this — the selection, the
    /// inspector, preview's next and previous — is asking about the thing
    /// rather than about the tile.
    var visibleObjects: [ObjectSnapshot] {
        contents.objects
    }

    /// The objects the current selection names.
    ///
    /// Home selects tiles and two tiles can name one object, so the thing is
    /// named once here — the batch actions favourite, move and delete a thing,
    /// not a tile.
    var selectedObjectIDs: Set<ObjectID> {
        selection
    }

    var hasSelection: Bool {
        !selection.isEmpty
    }

    var selectedObjects: [ObjectSnapshot] {
        let ids = selectedObjectIDs
        return visibleObjects.filter { ids.contains($0.id) }
    }

    /// Whether the destination on screen reads from Recently Deleted. Home
    /// never does, whichever place the canvas was last pointed at.
    var isShowingDeleted: Bool { !isShowingHome && scope == .recentlyDeleted }

    var availableSortFields: [ObjectSortField] {
        [.name, .dateAdded, .dateCreated, .kind, .size]
    }

    var currentFolderID: FolderID? {
        guard !isShowingHome else { return nil }
        if case .folder(let id) = scope { return id }
        return nil
    }

    func requestSearchFieldFocus() {
        searchFieldFocusRequests += 1
    }

    var previewedObject: ObjectSnapshot? {
        previewedObjectID.flatMap { id in visibleObjects.first { $0.id == id } }
    }

    /// Every folder in the library, flattened and indented, for the move menu.
    var allFolders: [(folder: FolderSnapshot, depth: Int)] {
        func flatten(_ nodes: [FolderNode], depth: Int) -> [(FolderSnapshot, Int)] {
            nodes.flatMap { [($0.folder, depth)] + flatten($0.children, depth: depth + 1) }
        }
        return flatten(folderTree, depth: 0)
    }

    /// The places the sidebar names, in the order it names them, as one
    /// sequence — what a change to the sidebar is choreographed against.
    private var sidebarPlaceIDs: [LibraryReference] {
        allFolders.map { .folder($0.folder.id) }
            + collections.map { .collection($0.id) }
            + tags.map { .tag($0.id) }
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
        let objects = visibleObjects
        guard let index = objects.firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + offset
        guard objects.indices.contains(target) else { return nil }
        return objects[target]
    }

    func stepPreview(_ offset: Int) {
        guard let current = previewedObjectID,
              let next = adjacentObject(to: current, offset: offset)
        else { return }
        previewedObjectID = next.id
        selectPreviewed(next)
    }

    /// Puts the selection and cursor on whatever preview has moved to.
    func selectPreviewed(_ object: ObjectSnapshot) {
        selection = [object.id]
        selectionAnchor = object.id
        cursor = .object(object.id)
    }
}

/// Where the sidebar can point. Home is not a query over objects, so it is not
/// a scope.
enum LibraryDestination: Hashable {
    case home
    case scope(LibraryScope)
}

/// One page on the iOS navigation stack: a place, or an object previewed in
/// front of it.
///
/// Identity is the page, not what it shows, so stepping a preview to the next
/// item changes the page without the stack treating it as a new one.
struct LibraryPage: Hashable, Identifiable {
    let id = UUID()
    let destination: LibraryDestination
    var previewedObjectID: ObjectID?

    static func == (lhs: LibraryPage, rhs: LibraryPage) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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

extension LocationContents {
    /// Everything here, folders ahead of objects, as one sequence of
    /// identities — what a change to the canvas is choreographed against.
    var itemIDs: [CanvasItemID] {
        folders.map { .folder($0.id) } + objects.map { .object($0.id) }
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

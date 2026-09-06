import SwiftUI
import UniformTypeIdentifiers
import NookLibrary
#if os(iOS)
import PhotosUI
#endif

/// The content canvas. Browsing and preview occupy the same space: opening an
/// object replaces the grid rather than stacking a window on top of it.
struct BrowseView: View {
    @Bindable var model: LibraryModel
    @State private var isDropTargeted = false
    /// Where the canvas actually drew each item, which is what tells an arrow
    /// key what "the row above" means in a layout that is not a uniform grid.
    @State private var itemFrames: [CanvasItemID: CGRect] = [:]
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isCanvasFocused: Bool
    #if os(iOS)
    @State private var isPhotosPickerPresented = false
    @State private var photoSelections: [PhotosPickerItem] = []
    #endif
    @State private var newCollectionTargets: [ObjectID]?
    @State private var draftCollectionName = ""

    var body: some View {
        ZStack {
            if let previewed = model.previewedObject {
                ObjectPreviewView(model: model, object: previewed)
                    .transition(.opacity)
            } else {
                canvas
                    .transition(.opacity)
            }
        }
        .motionAware(.smooth(duration: 0.22), value: model.previewedObjectID)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .searchable(text: $model.searchText, tokens: $model.searchTokens, prompt: searchPrompt) { token in
            Label(token.name, systemImage: token.symbolName)
        }
        .searchFocused($isSearchFocused)
        .onChange(of: model.searchFieldFocusRequests) { isSearchFocused = true }
        .onChange(of: isSearchFocused) { _, focused in model.isTextEntryFocused = focused }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.importFiles(at: urls) }
        }
        // Exporting asks for a folder rather than saving one file at a time,
        // because a selection is as ordinary a thing to export as one item.
        .fileImporter(
            isPresented: $model.isExportPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let directory = urls.first else {
                model.cancelExport()
                return
            }
            Task { await model.completeExport(to: directory) }
        }
        #if os(iOS)
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $photoSelections,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoSelections) { _, selections in
            guard !selections.isEmpty else { return }
            photoSelections = []
            Task { await importPhotos(selections) }
        }
        #endif
        .alert("New Collection", isPresented: newCollectionBinding) {
            TextField("Name", text: $draftCollectionName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = draftCollectionName
                let targets = newCollectionTargets ?? []
                Task { await model.createCollection(named: name, adding: targets) }
            }
        } message: {
            Text("Collections gather items from anywhere without moving them.")
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        Group {
            if model.scope == .hidden, !model.isShowingHiddenContent {
                hiddenDoor
            } else if let locked = model.lockedLocation {
                lockedState(locked)
            } else if model.contents.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            switch model.viewMode {
                            case .grid: gridCanvas
                            case .masonry: masonryCanvas
                            case .list: listCanvas
                            }
                        }
                        // Named on the content rather than the scroll view, so
                        // an item's measured frame describes where it sits in
                        // the canvas and does not change as the canvas scrolls.
                        .coordinateSpace(.named(canvasCoordinateSpace))
                    }
                    #if os(macOS)
                    .onTapGesture {
                        model.focus(.canvas)
                        model.deselectAll()
                    }
                    #endif
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isCanvasFocused)
                    .modifier(CanvasKeyboard(model: model, frames: itemFrames))
                    // Focus follows the model rather than being grabbed on
                    // appear: the sidebar is the other half of this, and a
                    // canvas that helps itself to the keyboard is a sidebar
                    // that never gets it.
                    .onAppear { syncFocus() }
                    .onChange(of: model.keyboardFocusRequest) { syncFocus() }
                    .onChange(of: isCanvasFocused) { _, focused in
                        if focused { model.focus(.canvas) }
                    }
                    // Leaving preview hands the keyboard back to the canvas,
                    // so the arrows keep working where they left off.
                    .onChange(of: model.previewedObjectID) { _, previewed in
                        if previewed == nil { model.focus(.canvas) }
                    }
                    // Walked in from the sidebar, rather than clicked into.
                    .onChange(of: model.canvasEntryRequest) {
                        model.lightFirstItemIfNothingIsLit()
                    }
                    .onChange(of: model.cursor) { _, cursor in
                        guard let cursor else { return }
                        proxy.scrollTo(cursor.uuid)
                    }
                    // A different layout is a different set of positions, and
                    // the old ones would answer the next arrow key wrongly.
                    // Discarding them is safe only because changing mode always
                    // relays the canvas, which is what reports the new ones:
                    // a frame that has not moved is never reported again.
                    .onChange(of: model.viewMode) { itemFrames = [:] }
                    .onChange(of: model.contents) {
                        // Whatever is still on the canvas has not moved, so its
                        // position stands. Only what has left is dropped, which
                        // keeps the map from growing as the user browses.
                        let present = Set(model.canvasOrder)
                        itemFrames = itemFrames.filter { present.contains($0.key) }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importFiles(at: urls) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay { if isDropTargeted { dropIndicator } }
    }

    private var gridCanvas: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 16)], spacing: 16) {
            ForEach(model.canvasItems) { item in
                switch item {
                case .folder(let folder):
                    FolderCard(folder: folder) { model.scope = .folder(folder.id) }
                        .draggable(FolderTransfer(id: folder.id))
                        .modifier(FolderDropTarget(model: model, folder: folder))
                        .canvasItem(.folder(folder.id), model: model, radius: 12, frames: $itemFrames)
                case .object(let object):
                    ObjectCard(object: object,
                               isSelected: model.selection.contains(object.id))
                    .modifier(ObjectItemBehavior(model: model, object: object, newCollection: startNewCollection))
                    .canvasItem(.object(object.id), model: model, radius: 12, frames: $itemFrames)
                }
            }
        }
        .padding(20)
    }

    private var masonryCanvas: some View {
        MasonryLayout(minimumColumnWidth: 168, spacing: 14) {
            ForEach(model.canvasItems) { item in
                switch item {
                case .folder(let folder):
                    FolderCard(folder: folder) { model.scope = .folder(folder.id) }
                        .draggable(FolderTransfer(id: folder.id))
                        .modifier(FolderDropTarget(model: model, folder: folder))
                        .canvasItem(.folder(folder.id), model: model, radius: 12, frames: $itemFrames)
                case .object(let object):
                    ObjectMasonryCard(object: object, isSelected: model.selection.contains(object.id))
                        .modifier(ObjectItemBehavior(model: model, object: object, newCollection: startNewCollection))
                        .canvasItem(.object(object.id), model: model, radius: 12, frames: $itemFrames)
                }
            }
        }
        .padding(20)
    }

    private var listCanvas: some View {
        LazyVStack(spacing: 1) {
            ForEach(model.canvasItems) { item in
                switch item {
                case .folder(let folder):
                    FolderListRow(folder: folder)
                        .itemClick { model.scope = .folder(folder.id) }
                        .draggable(FolderTransfer(id: folder.id))
                        .modifier(FolderDropTarget(model: model, folder: folder))
                        .canvasItem(.folder(folder.id), model: model, radius: 6, frames: $itemFrames)
                case .object(let object):
                    ObjectListRow(object: object, isSelected: model.selection.contains(object.id))
                        .modifier(ObjectItemBehavior(model: model, object: object, newCollection: startNewCollection))
                        .canvasItem(.object(object.id), model: model, radius: 6, frames: $itemFrames)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var dropIndicator: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .padding(8)
            .allowsHitTesting(false)
    }

    /// Hidden with nobody authenticated: reached by Back, or by a prompt the
    /// user answered with no. It says what is behind it and asks again, rather
    /// than showing an empty place that looks like nothing is hidden.
    private var hiddenDoor: some View {
        ContentUnavailableView {
            Label("Hidden", systemImage: "eye.slash")
        } description: {
            Text("Authenticate to see the items and folders you've hidden.")
        } actions: {
            Button("Show Hidden Items") {
                Task { await model.openHidden() }
            }
        }
    }

    /// A locked place is a door before it is a location, so it is drawn as
    /// one. Its name stays visible — the user has to be able to find what to
    /// authenticate against — while nothing it holds is drawn behind it.
    private func lockedState(_ location: (reference: LibraryReference, name: String)) -> some View {
        ContentUnavailableView {
            Label(location.name, systemImage: "lock.fill")
        } description: {
            Text("Authenticate to see what's in here.")
        } actions: {
            Button("Unlock") {
                Task { await model.unlockCurrentLocation() }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
        } description: {
            Text(emptyDescription)
        } actions: {
            if !model.searchText.isEmpty {
                Button("Clear Search") { model.searchText = "" }
            } else if model.scope != .recentlyDeleted, model.scope != .hidden {
                Button("Import Files…") { model.isImporterPresented = true }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.previewedObjectID == nil {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { model.goBack() }
                    .disabled(!model.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { model.goForward() }
                    .disabled(!model.canGoForward)
            }

            ToolbarItem {
                Picker("View", selection: viewModeBinding) {
                    ForEach(LibraryViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
            }

            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: sortFieldBinding) {
                        ForEach(sortFields, id: \.self) { field in
                            Text(field.displayName).tag(field)
                        }
                    }
                    Picker("Order", selection: sortAscendingBinding) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }

                    Divider()
                    Toggle("Folders First", isOn: foldersFirstBinding)

                    Divider()
                    // A change stays temporary unless the user says otherwise,
                    // so no location quietly acquires a permanent exception.
                    if model.canRememberLocation {
                        Toggle("Remember for This Location", isOn: rememberBinding)
                    }
                    Button("Use as Default Everywhere") {
                        model.useCurrentPreferencesAsDefault()
                    }
                } label: {
                    Label("View Options", systemImage: "arrow.up.arrow.down")
                }
            }

            ToolbarItem {
                Menu {
                    Button("Files…", systemImage: "folder") { model.isImporterPresented = true }
                    #if os(iOS)
                    Button("Photos…", systemImage: "photo.on.rectangle") {
                        isPhotosPickerPresented = true
                    }
                    #endif
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        Task { await model.importPasteboard() }
                    }
                } label: {
                    Label("Import", systemImage: "plus")
                }
            }
        }

        ToolbarItem {
            Button("Info", systemImage: "info.circle") {
                model.isInspectorPresented.toggle()
            }
        }
    }

    private var sortFields: [ObjectSortField] {
        var fields: [ObjectSortField] = [.name, .dateAdded, .dateCreated, .kind, .size]
        if case .collection = model.scope { fields.insert(.manual, at: 0) }
        return fields
    }

    // MARK: Bindings

    private var viewModeBinding: Binding<LibraryViewMode> {
        Binding(get: { model.viewMode },
                set: { mode in Task { await model.setViewMode(mode) } })
    }

    private var sortFieldBinding: Binding<ObjectSortField> {
        Binding(get: { model.sort.field },
                set: { field in
                    Task { await model.setSort(ObjectSort(field: field, ascending: model.sort.ascending)) }
                })
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(get: { model.sort.ascending },
                set: { ascending in
                    Task { await model.setSort(ObjectSort(field: model.sort.field, ascending: ascending)) }
                })
    }

    private var foldersFirstBinding: Binding<Bool> {
        Binding(get: { model.foldersFirst },
                set: { value in Task { await model.setFoldersFirst(value) } })
    }

    private var rememberBinding: Binding<Bool> {
        Binding(get: { model.isRememberingLocation },
                set: { value in Task { await model.setRememberingLocation(value) } })
    }

    private var newCollectionBinding: Binding<Bool> {
        Binding(get: { newCollectionTargets != nil },
                set: { if !$0 { newCollectionTargets = nil } })
    }

    // MARK: Actions

    #if os(iOS)
    /// Photos hands over bytes rather than a file on disk, so each selection
    /// arrives as data with whatever content type the library holds it in.
    private func importPhotos(_ selections: [PhotosPickerItem]) async {
        var items: [ImportItem] = []
        for selection in selections {
            guard let data = try? await selection.loadTransferable(type: Data.self) else { continue }
            let contentType = selection.supportedContentTypes.first ?? .data
            let name = selection.itemIdentifier.map { "\($0).\(contentType.preferredFilenameExtension ?? "dat")" }
            items.append(.data(data, contentType: contentType, suggestedName: name))
        }
        await model.importItems(items)
    }
    #endif

    /// Puts the keyboard where the model says it belongs.
    private func syncFocus() {
        isCanvasFocused = model.keyboardPane == .canvas
    }

    private func startNewCollection(with ids: [ObjectID]) {
        draftCollectionName = ""
        newCollectionTargets = ids
    }

    // MARK: Copy

    private var title: String {
        switch model.scope {
        case .folder: model.breadcrumbs.last?.name ?? "Folder"
        case .collection(let id): model.collections.first { $0.id == id }?.name ?? "Collection"
        case .tag(let id): model.tags.first { $0.id == id }?.name ?? "Tag"
        default: model.scope.displayName
        }
    }

    private var searchPrompt: String {
        switch model.scope {
        case .allObjects: "Search your library"
        default: "Search in \(title)"
        }
    }

    private var emptyTitle: String {
        if !model.searchText.isEmpty { return "No Results" }
        switch model.scope {
        case .inbox: return "Inbox Zero"
        case .favorites: return "No Favorites"
        case .recentlyDeleted: return "Nothing Deleted"
        case .hidden: return "Nothing Hidden"
        case .collection: return "Empty Collection"
        default: return "Nothing Here Yet"
        }
    }

    private var emptySymbol: String {
        if !model.searchText.isEmpty { return "magnifyingglass" }
        switch model.scope {
        case .inbox: return "tray"
        case .favorites: return "star"
        case .recentlyDeleted: return "trash"
        case .hidden: return "eye.slash"
        case .collection: return "rectangle.stack"
        default: return "square.grid.2x2"
        }
    }

    private var emptyDescription: String {
        if !model.searchText.isEmpty {
            return "No items in \(title) match “\(model.searchText)”."
        }
        switch model.scope {
        case .inbox: return "Anything you import without choosing a folder waits here."
        case .favorites: return "Items you favorite show up here."
        case .recentlyDeleted: return "Deleted items stay here for 30 days before they're removed."
        case .hidden: return "Items and folders you hide are kept here, and stay out of every other view. Unhiding one puts it back where it came from."
        case .collection: return "Drag items here, or use Add to Collection, to gather them without moving them."
        default: return "Drag files in, or import them, to get started."
        }
    }
}

/// Selection, opening, dragging, reordering and the context menu — applied
/// identically in all three view modes so behaviour never depends on layout.
struct ObjectItemBehavior: ViewModifier {
    let model: LibraryModel
    let object: ObjectSnapshot
    let newCollection: ([ObjectID]) -> Void

    func body(content: Content) -> some View {
        content
            // Clicking and arrowing reach the same two methods, so the pointer
            // and the keyboard cannot drift apart on what a click means.
            .itemClick(select: { model.select(object.id, modifiers: $0) },
                       open: { model.openObject(object) })
            .contextMenu {
                ObjectMenu(model: model, objects: targets, newCollection: newCollection)
            }
            .draggable(ObjectTransfer(id: object.id, fileURL: model.localURL(for: object)))
            .modifier(ManualReorderTarget(model: model, object: object))
    }

    private var targets: [ObjectSnapshot] {
        model.selection.contains(object.id) ? model.selectedObjects : [object]
    }
}

/// In a manually ordered collection, dropping one item onto another moves it
/// ahead of that item. Elsewhere there is no manual order to rearrange.
private struct ManualReorderTarget: ViewModifier {
    let model: LibraryModel
    let object: ObjectSnapshot

    private var isActive: Bool {
        if case .collection = model.scope { return model.sort.field == .manual }
        return false
    }

    func body(content: Content) -> some View {
        if isActive {
            content.dropDestination(for: ObjectTransfer.self) { transfers, _ in
                Task { await model.reorder(transfers.map(\.id), before: object.id) }
                return true
            }
        } else {
            content
        }
    }
}

/// Dropping objects on a folder relocates them: this is the true hierarchy.
struct FolderDropTarget: ViewModifier {
    let model: LibraryModel
    let folder: FolderSnapshot

    func body(content: Content) -> some View {
        content
            .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                Task { await model.move(transfers.map(\.id), to: folder.id) }
                return true
            }
            .dropDestination(for: FolderTransfer.self) { transfers, _ in
                guard let moved = transfers.first else { return false }
                Task { await model.moveFolder(moved.id, to: folder.id) }
                return true
            }
    }
}

/// The canvas's own coordinate space. Item frames are measured in it, so they
/// describe positions within the content rather than within the window.
private let canvasCoordinateSpace = "nook.canvas"

/// Every key the canvas answers to.
///
/// These are handled here, on the focused canvas, rather than as menu commands
/// with bare-key shortcuts: a menu command outranks the field editor, so an
/// arrow or a space bar promoted to the menu bar would be taken out of the
/// search field and every other place text is typed.
private struct CanvasKeyboard: ViewModifier {
    let model: LibraryModel
    let frames: [CanvasItemID: CGRect]

    func body(content: Content) -> some View {
        content
            // `.repeat` is what makes a held arrow key travel, rather than
            // moving one item and stopping.
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow],
                        phases: [.down, .repeat]) { press in
                guard let direction = CanvasDirection(press.key) else { return .ignored }
                let moved = model.moveCursor(direction,
                                             extendingSelection: press.modifiers.contains(.shift),
                                             frames: frames)
                // Left with nowhere left to go carries on the way it was
                // pointing and steps back into the sidebar, which is the
                // mirror of right stepping out of it.
                if !moved, direction == .left, !press.modifiers.contains(.shift) {
                    model.focus(.sidebar)
                }
                return .handled
            }
            .onKeyPress(.tab) {
                model.focusOtherPane()
                return .handled
            }
            .onKeyPress(keys: [.home, .end], phases: [.down]) { press in
                model.moveCursorToEdge(press.key == .home ? .up : .down,
                                       extendingSelection: press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.return) {
                guard model.cursor != nil else { return .ignored }
                model.openCursorItem()
                return .handled
            }
            .onKeyPress(.space) {
                guard model.canQuickLookCursorItem else { return .ignored }
                model.previewCursorItem()
                return .handled
            }
            .onKeyPress(.escape) {
                guard !model.selection.isEmpty else { return .ignored }
                model.deselectAll()
                return .handled
            }
    }
}

/// Marks one item on the canvas: measures where it sits, and shows the cursor
/// when the keyboard is resting on it.
private struct CanvasItemMarker: ViewModifier {
    let id: CanvasItemID
    let isCursor: Bool
    let radius: CGFloat
    @Binding var frames: [CanvasItemID: CGRect]

    func body(content: Content) -> some View {
        content
            .overlay {
                // Selection is a fill; the cursor is a ring. An item can carry
                // both, and a folder — which never joins a selection — has
                // only this to show that the keyboard is on it.
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(isCursor ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(canvasCoordinateSpace))
            } action: { frames[id] = $0 }
    }
}

private extension View {
    func canvasItem(
        _ id: CanvasItemID,
        model: LibraryModel,
        radius: CGFloat,
        frames: Binding<[CanvasItemID: CGRect]>
    ) -> some View {
        modifier(CanvasItemMarker(id: id, isCursor: model.cursor == id,
                                  radius: radius, frames: frames))
    }
}

enum OpenExternally {
    @MainActor
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

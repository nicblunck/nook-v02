import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

/// The content canvas. Browsing and preview occupy the same space: opening an
/// object replaces the grid rather than stacking a window on top of it.
struct BrowseView: View {
    @Bindable var model: LibraryModel
    /// A destination pushed from the compact Library list already receives
    /// native stack navigation. Its custom history pair would be relocated to
    /// the trailing toolbar beside the view controls, duplicating navigation.
    var showsHistoryControls = true
    /// Where the canvas actually drew each item, which is what tells an arrow
    /// key what "the row above" means in a layout that is not a uniform grid.
    @State private var itemFrames = GalleryFrames<CanvasItemID>()
    /// The grid's available width, measured once per layout pass rather than
    /// per item — what lets the Folders First shelf resolve the same columns
    /// the grid itself will, instead of drifting from them.
    @State private var gridContentWidth: CGFloat = 0
    /// Whether the Folders First shelf's drawer is open. Per view instance
    /// rather than remembered: a location whose folders were glanced at once
    /// and dismissed reopens with them showing again, the same way a fresh
    /// visit would.
    @State private var isFolderShelfExpanded = true
    /// The drawer's last-measured open height, so collapsing and reopening
    /// it animate between two concrete numbers instead of to or from
    /// whatever "natural size" resolves to, which does not interpolate.
    @State private var measuredFolderShelfHeight: CGFloat = 0
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isCanvasFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let previewed = model.previewedObject {
                ObjectPreviewView(model: model, object: previewed)
                    .transition(previewTransition)
            } else {
                canvas
                    .transition(previewTransition)
            }

            #if os(macOS)
            if model.previewedObjectID == nil {
                LibraryFloatingActionButton(model: model)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            #endif
        }
        .animation(reduceMotion ? NookMotion.reduced : NookMotion.presentation,
                   value: model.previewedObjectID)
        .navigationTitle(navigationTitle)
        .navigationSubtitle(navigationSubtitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            GalleryToolbar(model: model, showsHistoryControls: showsHistoryControls)
        }
        .searchable(text: $model.searchText, tokens: $model.searchTokens, prompt: searchPrompt) { token in
            Label(token.name, systemImage: token.symbolName)
        }
        .searchFocused($isSearchFocused)
        .onChange(of: model.searchFieldFocusRequests) { isSearchFocused = true }
        .onChange(of: isSearchFocused) { _, focused in model.isTextEntryFocused = focused }
        // Opening a preview swaps most of the toolbar's items out from under
        // it, and the search field is what AppKit hands the keyboard to when
        // nothing else claims it during that rebuild.
        .onChange(of: model.previewedObjectID) { _, previewed in
            if previewed != nil { isSearchFocused = false }
        }
    }

    private var previewTransition: AnyTransition {
        .motionAware(.scale(scale: 0.97).combined(with: .opacity),
                     reduceMotion: reduceMotion)
    }

    // MARK: Canvas

    private var canvas: some View {
        Group {
            if !model.isShowingHome, model.scope == .hidden, !model.isShowingHiddenContent {
                hiddenDoor
            } else if let locked = model.lockedLocation {
                lockedState(locked)
            } else if model.contents.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        items
                            // Named on the content rather than the scroll view,
                            // so an item's measured frame describes where it
                            // sits in the canvas and does not change as the
                            // canvas scrolls.
                            .coordinateSpace(.named(canvasCoordinateSpace))
                    }
                    .refreshable {
                        await model.refreshAll()
                    }
                    #if os(macOS)
                    .onTapGesture {
                        model.focus(.canvas)
                        model.deselectAll()
                    }
                    #endif
                    // Wins only where nothing more specific is hit: an item's
                    // own context menu, nested inside this one, takes right
                    // click before this ever sees it.
                    .contextMenu { LocationMenu(model: model) }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isCanvasFocused)
                    .modifier(CanvasKeyboard(model: model, frames: itemFrames))
                    .modifier(GalleryResizeGesture(model: model))
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
                    .onChange(of: model.viewMode) { itemFrames.removeAll() }
                    .onChange(of: model.itemScale) { itemFrames.removeAll() }
                    .onChange(of: model.masonryCaptionDisplay) { itemFrames.removeAll() }
                    .onChange(of: model.contents) {
                        itemFrames.keep(Set(model.canvasOrder))
                    }
                }
            }
        }
        .animation(reduceMotion ? NookMotion.reduced : NookMotion.presentation,
                   value: model.contents.isEmpty)
        .modifier(GalleryDropTarget(model: model))
    }

    /// One arrangement for all three view modes: what differs between a grid,
    /// a masonry wall and a list is the layout and the card, and both of those
    /// are decided in `Gallery`.
    private var items: some View {
        VStack(spacing: 0) {
            if showsFolderShelf {
                folderShelfSection
                    .padding(.bottom, 20)
            }
            canvasGrid
            CloudSyncStatusView(model: model)
        }
        // Measured before the inset padding below is applied, so this is the
        // same width the grid's own columns resolve against — which is what
        // lets the shelf's columns match them exactly rather than guess.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridContentWidth = $0 }
        .padding(model.viewMode.contentInsets)
        .animation(reduceMotion ? nil : NookMotion.reflow,
                   value: model.reflowRevision)
    }

    /// Folders First pulls locations out of the grid entirely rather than
    /// merely sorting them ahead of it: they read as a shelf of places, not
    /// as items that happen to come first among the things being browsed.
    private var showsFolderShelf: Bool {
        model.foldersFirst && !model.contents.folders.isEmpty
    }

    /// The grid's own columns, resolved from the same width the grid itself
    /// lays out against. Only meaningful in Grid mode — a masonry wall packs
    /// by height and a list is one column, so neither has columns for the
    /// shelf to line up with.
    private var alignedGridColumns: GalleryMetrics.Columns? {
        guard showsFolderShelf, model.viewMode == .grid else { return nil }
        return GalleryMetrics.resolvedColumns(for: gridContentWidth, scale: model.itemScale)
    }

    /// A drawer: a header that always shows "Folders" and a caret, and
    /// beneath it, the folders themselves — revealed or hidden by an
    /// animated height clip rather than by swapping in a different view, so
    /// opening and closing reads as the row actually sliding out or away
    /// rather than one view dissolving into another.
    private var folderShelfSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            folderShelfHeader
            folderShelfBody
        }
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.035))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // Bleeds the whole shelf — background, rounded corners, and the
        // folder row's own scroll clip inside it — 12pt past its column on
        // each side. Bleeding only the background (as this once did) leaves
        // the corner clip above sized to the narrower, unbled column, which
        // clips the row straight back down to it — a folder scrolled to the
        // row's edge then stops short of the box with a bare gap in between
        // instead of being cut off flush with it.
        .padding(.horizontal, -12)
    }

    /// The drawer's handle: always present, so there is always something
    /// there to name what is inside and to open it back up. The caret just
    /// points the way the drawer is about to move. The shelf around this
    /// bleeds 12pt past its column on each side, so this needs its own
    /// 12pt horizontal inset to land back where it was — flush with the
    /// column, with the caret centered in the box's actual corner rather
    /// than the wider, bled one.
    private var folderShelfHeader: some View {
        Button {
            withAnimation(reduceMotion ? nil : NookMotion.reflow) {
                isFolderShelfExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("Folders")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isFolderShelfExpanded ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFolderShelfExpanded ? "Hide Folders" : "Show Folders")
    }

    /// A horizontally scrolling row of locations, drawn at gallery size and
    /// spacing — in Grid mode, in the grid's own columns, so folders line up
    /// with the objects underneath. Its height is driven by state rather
    /// than by its own content, clipped to that height, and pinned to the
    /// top — so collapsing crops it away from the bottom up, the way a
    /// drawer's contents actually slide behind its face, and expanding
    /// grows it back out to the height it last measured itself at.
    private var folderShelfBody: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: GalleryMetrics.columnSpacing) {
                ForEach(model.contents.folders) { folder in
                    canvasItem(.folder(folder), mode: .grid, scale: model.itemScale)
                        .frame(width: folderShelfItemWidth)
                }
            }
            // The shelf around this scroll view bleeds 12pt past its column
            // on each side; padding the row in by the same amount keeps a
            // folder at rest aligned with the grid column beneath it, while
            // still leaving room to scroll out to the shelf's true, bled edge.
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            // Measured on the content itself, before the frame below locks
            // the scroll view to its last-known height — otherwise, once a
            // height is locked in, growing the items (larger object scale)
            // would only ever measure the already-clipped, stale height and
            // the shelf would never grow to hug its now-taller content.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                if isFolderShelfExpanded { measuredFolderShelfHeight = newHeight }
            }
        }
        .frame(height: folderShelfBodyHeight, alignment: .top)
        .clipped()
    }

    /// `nil` only until the drawer has measured itself once, so the very
    /// first (unanimated) layout can size to its natural height; every
    /// toggle after that animates between two concrete numbers, which is
    /// what actually interpolates smoothly.
    private var folderShelfBodyHeight: CGFloat? {
        guard isFolderShelfExpanded else { return 0 }
        return measuredFolderShelfHeight > 0 ? measuredFolderShelfHeight : nil
    }

    private var folderShelfItemWidth: CGFloat {
        alignedGridColumns?.width ?? max(84, 96 * model.itemScale)
    }

    /// What the grid itself draws. With Folders First on, folders have
    /// already been pulled into the shelf above, so only the objects remain.
    private var canvasGridItems: [CanvasItem] {
        showsFolderShelf ? model.contents.objects.map(CanvasItem.object) : model.canvasItems
    }

    private var canvasGrid: some View {
        GalleryLayout(mode: model.viewMode,
                      scale: model.itemScale,
                      masonryCaptionDisplay: model.masonryCaptionDisplay,
                      fixedColumns: alignedGridColumns) {
            ForEach(canvasGridItems) { item in canvasItem(item, mode: model.viewMode, scale: model.itemScale) }
        }
    }

    @ViewBuilder
    private func canvasItem(_ item: CanvasItem, mode: LibraryViewMode, scale: Double) -> some View {
        switch item {
        case .folder(let folder):
            let isSelected = model.cursor == .folder(folder.id)
            let isCursor = isSelected
            FolderItemView(folder: folder, mode: mode,
                           peeks: model.folderPeeks[folder.id] ?? [],
                           isSelected: isSelected, isCursor: isCursor,
                           scale: scale,
                           masonryCaptionDisplay: model.masonryCaptionDisplay,
                           select: { model.selectFolder(folder.id, modifiers: $0) }) {
                model.navigate(to: .scope(.folder(folder.id)))
            }
            .contextMenu {
                FolderMenu(model: model, folder: folder) {
                    model.navigate(to: .scope(.folder(folder.id)))
                }
            }
            .draggable(FolderTransfer(id: folder.id))
            .modifier(FolderDropTarget(model: model, folder: folder))
            .galleryItem(CanvasItemID.folder(folder.id),
                         isCursor: isCursor,
                         mode: mode,
                         radius: mode.itemCornerRadius,
                         in: canvasCoordinateSpace,
                         frames: itemFrames)
            .plopIn(trigger: arrivalTrigger(for: folder.id),
                    order: arrivalOrder(for: folder.id))
            .transition(itemTransition)
        case .object(let object):
            let isSelected = model.selection.contains(object.id)
            let isCursor = model.cursor == .object(object.id)
            ObjectItemView(object: object, mode: mode,
                           isSelected: isSelected, isCursor: isCursor,
                           scale: scale,
                           masonryCaptionDisplay: model.masonryCaptionDisplay,
                           showsMasonryTypeLabels: model.showsMasonryTypeLabels)
            .modifier(ObjectItemBehavior(
                model: model,
                object: object,
                isSelected: isSelected,
                select: { model.select(object.id, modifiers: $0) },
                open: { model.openObject(object) }
            ))
            .galleryItem(CanvasItemID.object(object.id),
                         isCursor: isCursor,
                         mode: mode,
                         radius: mode.itemCornerRadius,
                         in: canvasCoordinateSpace,
                         frames: itemFrames)
            .plopIn(trigger: arrivalTrigger(for: object.id),
                    order: arrivalOrder(for: object.id))
            .transition(itemTransition)
        }
    }

    private var itemTransition: AnyTransition {
        let removal = AnyTransition.scale(scale: 0.88).combined(with: .opacity)
        return .asymmetric(
            insertion: .identity,
            removal: .motionAware(removal, reduceMotion: reduceMotion)
        )
        .animation(reduceMotion ? NookMotion.reduced : NookMotion.reflow)
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
            } else if model.isShowingHome {
                Button("Import Files…") { model.isImporterPresented = true }
            } else if model.scope != .recentlyDeleted, model.scope != .hidden {
                Button("Import Files…") { model.isImporterPresented = true }
            }
        }
    }

    // MARK: Actions

    private func arrivalTrigger(for id: ObjectID) -> Int? {
        guard let arrival = model.arrival, arrival.destination == model.destination,
              arrival.objectOrder(id) != nil else { return nil }
        return arrival.revision
    }

    private func arrivalOrder(for id: ObjectID) -> Int {
        guard let arrival = model.arrival, arrival.destination == model.destination else { return 0 }
        return arrival.objectOrder(id) ?? 0
    }

    private func arrivalTrigger(for id: FolderID) -> Int? {
        guard let arrival = model.arrival, arrival.destination == model.destination,
              arrival.folderOrder(id) != nil else { return nil }
        return arrival.revision
    }

    private func arrivalOrder(for id: FolderID) -> Int {
        guard let arrival = model.arrival, arrival.destination == model.destination else { return 0 }
        return arrival.folderOrder(id) ?? 0
    }

    /// Puts the keyboard where the model says it belongs.
    private func syncFocus() {
        isCanvasFocused = model.keyboardPane == .canvas
    }

    // MARK: Copy

    private var title: String {
        if model.isShowingHome { return "All" }
        return switch model.scope {
        case .folder: model.breadcrumbs.last?.name ?? "Folder"
        case .collection(let id): model.collections.first { $0.id == id }?.name ?? "Collection"
        case .tag(let id): model.tags.first { $0.id == id }?.name ?? "Tag"
        default: model.scope.displayName
        }
    }

    private var navigationTitle: String {
        model.previewedObject?.title ?? (model.isShowingHome ? "All" : title)
    }

    private var navigationSubtitle: String {
        if let object = model.previewedObject {
            return metadataParts(for: object, includesKind: true).joined(separator: " · ")
        }

        let itemCount = model.contents.objects.count
        let folderCount = model.contents.folders.count
        var parts: [String]

        if model.searchText.isEmpty {
            parts = [inflectedString("^[\(itemCount) item](inflect: true)")]
            if folderCount > 0 {
                parts.append(inflectedString("^[\(folderCount) folder](inflect: true)"))
            }
        } else {
            let resultCount = itemCount + folderCount
            parts = [inflectedString("^[\(resultCount) result](inflect: true)")]
        }

        let selectedObjects = model.contents.objects.filter { model.selection.contains($0.id) }
        if !model.selection.isEmpty {
            parts.append(inflectedString("^[\(model.selection.count) item](inflect: true) selected"))
        }

        if selectedObjects.count == 1, let object = selectedObjects.first {
            parts.append(contentsOf: metadataParts(for: object, includesKind: false))
        } else if selectedObjects.count > 1 {
            let sizes = selectedObjects.compactMap(\.byteSize)
            if sizes.count == selectedObjects.count,
               let totalSize = Format.bytes(sizes.reduce(0, +)) {
                parts.append(totalSize)
            }
        }

        return parts.joined(separator: " · ")
    }

    private func metadataParts(for object: ObjectSnapshot, includesKind: Bool) -> [String] {
        var parts: [String] = includesKind ? [object.kind.displayName] : []

        if let fileExtension = fileExtension(for: object),
           !parts.contains(where: { $0.caseInsensitiveCompare(fileExtension) == .orderedSame }) {
            parts.append(fileExtension)
        } else if parts.isEmpty {
            parts.append(object.kind.displayName)
        }

        if let size = Format.bytes(object.byteSize) { parts.append(size) }
        if let dimensions = Format.dimensions(object) { parts.append(dimensions) }
        if let duration = Format.duration(object.duration) { parts.append(duration) }
        if let pageCount = object.pageCount {
            parts.append(inflectedString("^[\(pageCount) page](inflect: true)"))
        }
        if object.kind == .link, let domain = object.sourceDomain { parts.append(domain) }

        return parts
    }

    private func inflectedString(_ resource: LocalizedStringResource) -> String {
        let localized = AttributedString(localized: resource)
        return String(localized.inflected().characters)
    }

    private func fileExtension(for object: ObjectSnapshot) -> String? {
        if let filename = object.originalFilename {
            let fileExtension = URL(fileURLWithPath: filename).pathExtension
            if !fileExtension.isEmpty { return fileExtension.uppercased() }
        }
        return object.contentTypeIdentifier
            .flatMap(UTType.init)
            .flatMap(\.preferredFilenameExtension)?
            .uppercased()
    }

    private var searchPrompt: String {
        if model.isShowingHome { return "Search your library" }
        return switch model.scope {
        case .allObjects: "Search your library"
        default: "Search in \(title)"
        }
    }

    private var emptyTitle: String {
        if !model.searchText.isEmpty { return "No Results" }
        if model.isShowingHome { return "Your Library Is Empty" }
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
        if model.isShowingHome { return "tray" }
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
        if model.isShowingHome {
            return "Drag files in, import them, or share something to Nook."
        }
        switch model.scope {
        case .inbox: return "Anything you import without choosing a folder waits here."
        case .favorites: return "Items you favorite show up here."
        case .recentlyDeleted: return "Deleted items stay here for 30 days before they're removed."
        case .hidden: return "Items and folders you hide move here, and stay out of every other view. Unhiding one sends it back to the Inbox."
        case .collection: return "Drag items here, or use Add to Collection, to gather them without moving them."
        default: return "Drag files in, or import them, to get started."
        }
    }
}

/// The open folder and Inbox are real storage destinations. Dropping on empty
/// canvas space is therefore a useful move, while collections, tags and other
/// read-only scopes should not pretend to be folders.
private struct CanvasObjectDropTarget: ViewModifier {
    let model: LibraryModel

    private var destination: FolderID? {
        if model.isShowingHome { return nil }
        return switch model.scope {
        case .inbox: nil
        case .folder(let id): id
        default: nil
        }
    }

    private var isActive: Bool {
        if model.isShowingHome { return false }
        switch model.scope {
        case .inbox, .folder: return true
        default: return false
        }
    }

    func body(content: Content) -> some View {
        if isActive {
            content.dropDestination(for: ObjectTransfer.self) { transfers, _ in
                let ids = transfers.flatMap(\.ids)
                guard !ids.isEmpty,
                      !transfers.allSatisfy({ $0.isAlreadyIn(destination) })
                else { return false }
                Task { await model.move(ids, to: destination) }
                return true
            }
        } else {
            content
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
    let frames: GalleryFrames<CanvasItemID>

    func body(content: Content) -> some View {
        content
            // `.repeat` is what makes a held arrow key travel, rather than
            // moving one item and stopping.
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow],
                        phases: [.down, .repeat]) { press in
                guard let direction = CanvasDirection(press.key) else { return .ignored }
                let moved = model.moveCursor(direction,
                                             extendingSelection: press.modifiers.contains(.shift),
                                             frames: frames.frames)
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
                guard model.hasSelection else { return .ignored }
                model.deselectAll()
                return .handled
            }
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

#if DEBUG
#Preview {
    PreviewHost { model in
        BrowseView(model: model)
    }
    .frame(minWidth: 600, minHeight: 500)
}
#endif

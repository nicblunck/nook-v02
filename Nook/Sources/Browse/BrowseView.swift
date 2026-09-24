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
    /// The page this canvas is on, when it is one of the iOS navigation
    /// stack's. A page is either a place or a preview, never both: the stack
    /// shows the canvas beneath a preview as a page of its own.
    var stackPage: LibraryPage?
    /// Whether a page on the stack holds its items back until its own place
    /// has loaded, rather than showing the last place's in the meantime.
    var showsPlaceOnlyOnceLoaded = true
    /// What a preview page last showed, so it keeps showing it while it
    /// slides away after the preview has closed.
    @State private var lastPreviewed: ObjectSnapshot?
    /// Where a page on the stack is scrolled to, so coming back to it lands
    /// where it was left.
    @State private var scrollPosition = ScrollPosition(edge: .top)
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
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isCanvasFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #else
    /// The picture that zooms out of its tile as an object opens and back in
    /// as it closes.
    @State private var macZoom = MacPreviewZoom()
    /// What was open as of the last change, so a render can tell an object
    /// just opened from the gallery from one stepped to.
    @State private var shownPreviewID: ObjectID?
    @Environment(\.thumbnailLoader) private var thumbnailLoader
    #endif

    var body: some View {
        content
            .onChange(of: model.previewedObject, initial: true) { _, object in
                #if os(macOS)
                if let object { lastPreviewed = object }
                #else
                if let object, stackPage?.previewedObjectID != nil { lastPreviewed = object }
                #endif
            }
    }

    /// The object open in preview on this canvas, if any.
    private var previewed: ObjectSnapshot? {
        guard let stackPage else { return model.previewedObject }
        guard stackPage.previewedObjectID != nil else { return nil }
        return model.previewedObject ?? lastPreviewed
    }

    /// Whether this canvas is a page on the stack whose place has not loaded
    /// yet. What the model holds then still belongs to the page it came from,
    /// and showing it here would show that page twice.
    private var isAwaitingPlace: Bool {
        guard let stackPage, stackPage.previewedObjectID == nil, showsPlaceOnlyOnceLoaded else { return false }
        return model.contentsDestination != stackPage.destination
    }

    /// On iPhone the search field lives in the bottom bar alongside Home
    /// and Add, always there while browsing rather than summoned.
    private var docksSearchInBottomBar: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact && previewed == nil && !model.isSelecting
        #else
        false
        #endif
    }

    private func presentSearch() {
        isSearchPresented = true
        isSearchFocused = true
    }

    private func selectContentFilter(_ filter: LibraryContentFilter) {
        Task {
            await model.toggleContentFilter(filter)
        }
    }

    private var content: some View {
        ZStack {
            #if os(macOS)
            // The gallery stays where it is under an open object, as it does
            // in Photos: scrolled where it was left, with each tile there for
            // the object's picture to zoom out of and back into.
            browsingCanvas
                .allowsHitTesting(previewed == nil)
                .accessibilityHidden(previewed != nil)
            if let previewed {
                ObjectPreviewView(model: model, object: previewed, showsBackButton: true)
                    // Held back while its picture zooms out of the tile.
                    .opacity(isAwaitingZoom(previewed) ? 0 : 1)
                    // The zoom is the whole transition when there is one.
                    .transition(zooms(previewed) ? .identity : previewTransition)
            }
            #else
            if let previewed {
                ObjectPreviewView(model: model, object: previewed, showsBackButton: stackPage == nil)
                    .transition(previewTransition)
            } else if stackPage?.previewedObjectID != nil {
                // A preview page whose object is no longer there to show.
                Color.clear
            } else {
                browsingCanvas
                    .transition(previewTransition)
            }
            #endif

            #if os(macOS)
            if model.previewedObjectID == nil {
                MacAddContentToolbar(model: model)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    // Leaves with the canvas and comes back with it, on the
                    // same beat.
                    .transition(.staged(
                        exit: .move(edge: .bottom).combined(with: .opacity),
                        enter: .move(edge: .bottom).combined(with: .opacity),
                        reduceMotion: reduceMotion
                    ))
            }
            #endif
        }
        #if os(macOS)
        .coordinateSpace(.named(MacPreviewZoom.coordinateSpace))
        .overlay { MacPreviewZoomOverlay(zoom: macZoom) }
        .environment(\.macPreviewZoom, macZoom)
        // Opening from the gallery and closing back to it; stepping from one
        // object to the next is the pages' to show.
        .onChange(of: model.previewedObjectID) { opened, current in
            shownPreviewID = current
            guard !reduceMotion else { return }
            if opened == nil, let object = model.previewedObject, object.id == current {
                macZoom.open(object)
            } else if current == nil, let object = lastPreviewed, object.id == opened {
                macZoom.close(object)
            }
            if let object = model.previewedObject { macZoom.prepare(object) }
        }
        .onAppear { macZoom.loader = thumbnailLoader }
        #endif
        .animation(reduceMotion ? NookMotion.reduced : NookMotion.presentation,
                   value: previewed?.id)
        .navigationTitle(navigationTitle)
        .navigationSubtitle(navigationSubtitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Select All takes Back's place while selecting, and the edge swipe
        // goes with it: leaving mid-selection would drop what was picked.
        .navigationBarBackButtonHidden(model.isSelecting)
        #endif
        .toolbar {
            // A page on the stack goes back with the system's own back button.
            GalleryToolbar(model: model,
                           showsHistoryControls: showsHistoryControls && stackPage == nil,
                           isPreviewing: previewed != nil)
            #if os(iOS)
            // This screen's own copy rather than the root list's, since it
            // is the one with a search field to dock between Home and Add.
            if model.isSelecting, previewed == nil {
                SelectionActionsToolbar(model: model)
            } else if docksSearchInBottomBar {
                CompactAddContentToolbar(model: model, includesSearch: true)
            }
            #endif
        }
        // Opening a preview swaps most of the toolbar's items out from under
        // it, and the search field is what AppKit hands the keyboard to when
        // nothing else claims it during that rebuild.
        .onChange(of: model.previewedObjectID) { _, previewed in
            if previewed != nil {
                isSearchPresented = false
                isSearchFocused = false
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                LibraryToastView(toast: toast)
                    .id(toast.id)
                    .padding(.horizontal, 16)
                    #if os(macOS)
                    // The gallery's add-content dock owns its bottom center.
                    // Confirmations stack above it while the dock is present.
                    .padding(.bottom, model.previewedObjectID == nil ? 88 : 20)
                    #else
                    .padding(.bottom, 20)
                    #endif
                    // A confirmation arriving on the heels of another waits
                    // for it to leave rather than sliding up through it.
                    .transition(.staged(
                        exit: .move(edge: .bottom).combined(with: .opacity),
                        enter: .move(edge: .bottom).combined(with: .opacity),
                        reduceMotion: reduceMotion
                    ))
            }
        }
        .animation(
            reduceMotion ? NookMotion.reduced : NookMotion.presentation,
            value: model.toast
        )
    }

    /// Search only makes sense while browsing, and scoping it to the canvas
    /// rather than the shared container is what keeps it out of the detail
    /// view entirely — there's nothing here to search once an object is open.
    private var browsingCanvas: some View {
        canvas
            .searchable(
                text: $model.searchText,
                tokens: $model.searchTokens,
                isPresented: $isSearchPresented,
                prompt: searchPrompt
            ) { token in
                Label(token.name, systemImage: token.symbolName)
            }
            // Keep the system search field out of the toolbar until
            // Search or Command-F explicitly asks for it — except on
            // iPhone, where it's always docked in the bottom bar.
            // Passing nil restores the same default item without
            // branching the view and losing its identity.
            .toolbar(removing: isSearchPresented || docksSearchInBottomBar ? nil : .search)
            .searchFocused($isSearchFocused)
            // Under an open object there is nothing here to search.
            .onChange(of: model.searchFieldFocusRequests) {
                if previewed == nil { presentSearch() }
            }
            .onChange(of: isSearchFocused) { _, focused in
                model.isTextEntryFocused = focused
            }
            .onChange(of: isSearchPresented) { wasPresented, presented in
                guard wasPresented, !presented else { return }
                isSearchFocused = false
                model.searchText = ""
            }
    }

    #if os(macOS)
    /// Whether `object` opens or closes by zooming out of or back into its
    /// tile rather than by the usual fade.
    private func zooms(_ object: ObjectSnapshot) -> Bool {
        guard !reduceMotion, macZoom.canZoom(object) else { return false }
        return shownPreviewID == nil || macZoom.closes(object)
    }

    /// Whether the viewer for `object` is still waiting on its picture to
    /// land — from the very render that opens it, before any change handler
    /// has had a chance to say so.
    private func isAwaitingZoom(_ object: ObjectSnapshot) -> Bool {
        macZoom.isOpening || (shownPreviewID == nil && zooms(object))
    }
    #endif

    /// Browsing gives way to preview and preview gives way back to browsing:
    /// whichever is leaving settles out before the other settles in.
    private var previewTransition: AnyTransition {
        .staged(exit: .scale(scale: 0.97).combined(with: .opacity),
                enter: .scale(scale: 0.97).combined(with: .opacity),
                reduceMotion: reduceMotion)
    }

    // MARK: Canvas

    private var canvas: some View {
        Group {
            if !model.isShowingHome, model.scope == .hidden, !model.isShowingHiddenContent {
                hiddenDoor
                    .transition(swapTransition)
            } else if let locked = model.lockedLocation {
                lockedState(locked)
                    .transition(swapTransition)
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
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentOffset.y + geometry.contentInsets.top
                    } action: { _, offset in
                        if let stackPage { model.rememberScrollOffset(offset, for: stackPage.id) }
                    }
                    .onAppear {
                        if let stackPage, let offset = model.scrollOffset(for: stackPage.id) {
                            scrollPosition.scrollTo(y: offset)
                        }
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
                .transition(swapTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [galleryAccentColor.opacity(0.3), galleryAccentColor.opacity(0)],
                startPoint: .bottom,
                endPoint: .top
            )
            .ignoresSafeArea()
        }
        .modifier(GalleryDropTarget(model: model))
    }

    /// One thing standing in for another in the same space — a door for a
    /// canvas, an empty state for a grid: a plain staged fade.
    private var swapTransition: AnyTransition {
        .staged(reduceMotion: reduceMotion)
    }

    private var galleryAccentColor: Color {
        model.settings.accentColor ?? .accentColor
    }

    /// The gap above the filter bar and between it and whatever follows
    /// (the folder shelf or the grid). Tighter than the gallery's own
    /// column inset — the filter bar reads as chrome sitting close under
    /// the toolbar, not as another row of gallery content.
    private var filterBarGap: CGFloat { 12 }

    /// Keyed on the place the contents came from, so arriving somewhere else
    /// swaps the whole canvas — the old place fades out, then the new one
    /// fades in — while a change within the same place is choreographed item
    /// by item in `placeContents`. Nothing is drawn until the first place has
    /// loaded, so launch does not open on an empty state that is about to be
    /// replaced. The stack keeps the two places in the same spot while one
    /// gives way to the other.
    private var items: some View {
        ZStack(alignment: .top) {
            if let place = model.contentsDestination, !isAwaitingPlace {
                placeContents
                    .id(place)
                    .transition(swapTransition)
            }
        }
    }

    /// One arrangement for all three view modes: what differs between a grid,
    /// a masonry wall and a list is the layout and the card, and both of those
    /// are decided in `Gallery`.
    private var placeContents: some View {
        VStack(spacing: 0) {
            LibraryContentFilterBar(
                selection: model.contentFilter,
                available: model.availableContentFilters,
                change: model.contentFilterChange,
                tint: galleryAccentColor,
                horizontalInset: model.viewMode.contentInsets.leading,
                select: selectContentFilter
            )

            if model.contents.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical, alignment: .center) { length, _ in
                        max(240, length - 44)
                    }
                    .padding(.horizontal, model.viewMode.contentInsets.leading)
                    .transition(swapTransition)
            } else {
                VStack(spacing: 0) {
                    if showsFolderShelf {
                        folderShelfSection
                            .padding(.bottom, model.viewMode.contentInsets.top)
                            .transition(folderShelfTransition)
                    }
                    canvasGrid
                    CloudSyncStatusView(model: model)
                }
                // Cards retain the gallery column inset. The filter scroller
                // above deliberately sits outside this padding so its clipping
                // boundary reaches both viewport edges.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridContentWidth = $0 }
                .padding(.horizontal, model.viewMode.contentInsets.leading)
                .padding(.top, filterBarGap)
                .transition(swapTransition)
            }
        }
        .padding(.top, filterBarGap)
        .padding(.bottom, model.viewMode.contentInsets.bottom)
        // Whatever stays moves into place with the reflow spring — held back,
        // when something is leaving, until it has left. A change of
        // arrangement (sort, Folders First, captions) has no exit to wait on
        // and moves at once.
        .animation(model.contentsChange.shift(reduceMotion: reduceMotion),
                   value: ReflowKey(contents: model.contents, revision: model.reflowRevision))
    }

    /// What the grid answers to with a move: the items themselves, and the
    /// preference-driven rearrangements the model counts.
    private struct ReflowKey: Equatable {
        let contents: LocationContents
        let revision: Int
    }

    /// Folders First pulls locations out of the grid entirely rather than
    /// merely sorting them ahead of it: they read as a shelf of places, not
    /// as items that happen to come first among the things being browsed.
    private var showsFolderShelf: Bool {
        model.foldersFirst && !model.contents.folders.isEmpty
    }

    /// The shelf appearing with the folders that fill it arrives on their
    /// beat. Appearing for a change of arrangement instead, it waits for the
    /// folders to leave the grid and the objects to close up behind them.
    private var folderShelfTransition: AnyTransition {
        let change = model.contentsChange
        let enterDelay = change.inserts
            ? change.enterDelay(reduceMotion: reduceMotion)
            : (reduceMotion ? NookMotion.reducedDuration
                            : NookMotion.exitDuration + NookMotion.shiftDuration)
        return .staged(enterDelay: enterDelay, reduceMotion: reduceMotion)
    }

    /// The columns a Gallery grid would resolve at this width, whatever view
    /// is actually showing. The shelf is drawn in these in every mode, so a
    /// folder is the same size, and the row the same rhythm, in List and
    /// Masonry as in Gallery — switching views must not make the folders
    /// jump. Only the grid itself is also laid out in them; see
    /// `gridFixedColumns`.
    private var shelfColumns: GalleryMetrics.Columns? {
        guard showsFolderShelf else { return nil }
        return GalleryMetrics.resolvedColumns(for: gridContentWidth, scale: model.itemScale)
    }

    /// The shelf's columns, handed to the grid so the objects underneath
    /// line up with the folders above. Only in Grid mode — a masonry wall
    /// packs by height and a list is one column, so neither has columns to
    /// pin.
    private var gridFixedColumns: GalleryMetrics.Columns? {
        model.viewMode == .grid ? shelfColumns : nil
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
    }

    /// The drawer's handle: always present, so there is always something
    /// there to name what is inside and to open it back up. The caret just
    /// points the way the drawer is about to move.
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

    /// The fallback only covers the first layout pass, before the width has
    /// been measured; it is the grid's minimum cell width, so it is as close
    /// to what the measured answer will be as an unmeasured guess can get.
    private var folderShelfItemWidth: CGFloat {
        shelfColumns?.width ?? GalleryMetrics.cellWidthRange(scale: model.itemScale).lowerBound
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
                      fixedColumns: gridFixedColumns) {
            ForEach(canvasGridItems) { item in canvasItem(item, mode: model.viewMode, scale: model.itemScale) }
        }
    }

    @ViewBuilder
    private func canvasItem(_ item: CanvasItem, mode: LibraryViewMode, scale: Double) -> some View {
        switch item {
        case .folder(let folder):
            let isSelected = model.folderSelection.contains(folder.id)
            let isCursor = model.cursor == .folder(folder.id)
            FolderItemView(folder: folder, mode: mode,
                           peeks: model.folderPeeks[folder.id] ?? [],
                           isSelected: isSelected, isCursor: isCursor,
                           scale: scale,
                           masonryCaptionDisplay: model.masonryCaptionDisplay,
                           select: { model.selectFolder(folder.id, modifiers: $0) }) {
                // While selecting, a tap picks the folder rather than going in.
                if model.isSelecting {
                    model.toggleSelection(.folder(folder.id))
                } else {
                    Task { await model.openFolder(folder.id) }
                }
            }
            .selectionMark(isSelecting: model.isSelecting, isSelected: isSelected, mode: mode)
            .contextMenu {
                // Part of a larger selection: the menu is the selection's.
                if isSelected, model.selectedItemCount > 1 {
                    SelectionMenu(model: model,
                                  objects: model.selectedObjects,
                                  folders: model.selectedFolders)
                } else {
                    FolderMenu(model: model, folder: folder) {
                        Task { await model.openFolder(folder.id) }
                    }
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
                    order: arrivalOrder(for: folder.id),
                    delay: model.contentsChange.enterDelay(reduceMotion: reduceMotion))
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
                    order: arrivalOrder(for: object.id),
                    delay: model.contentsChange.enterDelay(reduceMotion: reduceMotion))
            .transition(itemTransition)
        }
    }

    /// An item leaving shrinks away first; one arriving waits until whatever
    /// left has gone and whatever stayed has settled, then fades in. An
    /// explicit arrival still plops — `plopIn` holds it back by the same
    /// wait, so the plop lands on the same beat the fade would have.
    private var itemTransition: AnyTransition {
        model.contentsChange.itemTransition(
            exit: .scale(scale: 0.88).combined(with: .opacity),
            enter: .scale(scale: 0.96).combined(with: .opacity),
            reduceMotion: reduceMotion
        )
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
        if let previewed { return previewed.title }
        // A page is titled as soon as it arrives, not once its place has
        // loaded.
        if let stackPage { return model.title(for: stackPage.destination) }
        return model.isShowingHome ? "All" : title
    }

    private var navigationSubtitle: String {
        if let object = previewed {
            return metadataParts(for: object).joined(separator: " · ")
        }
        if isAwaitingPlace { return "" }

        let itemCount = model.contents.objects.count
        let folderCount = model.contents.folders.count
        var parts: [String]

        if model.searchText.isEmpty {
            if model.contentFilter == .folders {
                parts = [inflectedString("^[\(folderCount) folder](inflect: true)")]
            } else {
                parts = [inflectedString("^[\(itemCount) item](inflect: true)")]
            }
            if model.contentFilter != .folders, folderCount > 0 {
                parts.append(inflectedString("^[\(folderCount) folder](inflect: true)"))
            }
        } else {
            let resultCount = itemCount + folderCount
            parts = [inflectedString("^[\(resultCount) result](inflect: true)")]
        }

        return parts.joined(separator: " · ")
    }

    private func metadataParts(for object: ObjectSnapshot) -> [String] {
        var parts = [object.kind.displayName]

        if let fileExtension = fileExtension(for: object),
           fileExtension.caseInsensitiveCompare(object.kind.displayName) != .orderedSame {
            parts.append(fileExtension)
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

    private var emptyTitle: LocalizedStringResource {
        if !model.searchText.isEmpty { return "No Results" }
        if let filter = model.contentFilter { return filter.emptyTitle }
        if model.isShowingHome { return "Your Library Is Empty" }
        switch model.scope {
        case .inbox: return "Inbox Zero"
        case .favorites: return "No Favorites"
        case .trash: return "Trash Is Empty"
        case .hidden: return "Nothing Hidden"
        case .collection: return "Empty Collection"
        default: return "Nothing Here Yet"
        }
    }

    private var emptySymbol: String {
        if !model.searchText.isEmpty { return "magnifyingglass" }
        if let filter = model.contentFilter { return filter.systemImage }
        if model.isShowingHome { return "tray" }
        switch model.scope {
        case .inbox: return "tray"
        case .favorites: return "star"
        case .trash: return "trash"
        case .hidden: return "eye.slash"
        case .collection: return "rectangle.stack"
        default: return "square.grid.2x2"
        }
    }

}

/// An edge-to-edge horizontal scroller at the top of the gallery content.
/// Its own clipping boundary reaches the viewport edges; the small inset lives
/// inside the scroll content, so pills can travel all the way across without
/// being cut off by the gallery's card-column padding.
private struct LibraryContentFilterBar: View {
    let selection: LibraryContentFilter?
    /// Which pills are worth showing here — a type with nothing behind it
    /// at this location doesn't get a pill.
    let available: Set<LibraryContentFilter>
    /// The stages the latest change to `available` needs.
    let change: MotionChoreography
    let tint: Color
    /// Matches the gallery's own column inset, so the first pill's leading
    /// edge lines up with the folder shelf and the grid beneath it instead
    /// of sitting closer to the viewport edge than they do.
    var horizontalInset: CGFloat = 20
    let select: (LibraryContentFilter) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal) {
            // One container, so the pills share a sampling pass instead of
            // each lensing the others' glass. No spacing: neighbours stay
            // separate pills at rest rather than melting into one bar.
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(LibraryContentFilter.allCases.filter(available.contains)) { filter in
                        LibraryContentFilterButton(
                            filter: filter,
                            isSelected: selection == filter,
                            tint: tint,
                            action: { select(filter) }
                        )
                        // A pill that has lost its last item fades out; the rest
                        // close the gap; one earning its place fades in last.
                        .transition(change.itemTransition(
                            exit: .scale(scale: 0.9).combined(with: .opacity),
                            enter: .scale(scale: 0.9).combined(with: .opacity),
                            reduceMotion: reduceMotion
                        ))
                    }
                }
            }
            .padding(.horizontal, horizontalInset)
            .animation(change.shift(reduceMotion: reduceMotion), value: available)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryContentFilterButton: View {
    let filter: LibraryContentFilter
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(filter.title)
            } icon: {
                Image(systemName: filter.systemImage)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            // The selected pill takes the location's tint into its glass;
            // the rest stay clear glass over whatever scrolls beneath.
            .glassEffect(
                isSelected
                    ? .regular.tint(tint.opacity(0.18)).interactive()
                    : .regular.interactive(),
                in: .capsule
            )
            // The capsule hugs its label; the surrounding frame keeps the
            // control's hit target comfortably accessible.
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .motionAware(NookMotion.interaction, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                Task { await model.openCursorItem() }
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
            // Delete asks before anything goes: to the Trash, or — for what
            // is in the Trash already — out of it for good.
            .onKeyPress(.delete) {
                model.requestTrashForKeyboard() ? .handled : .ignored
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

#if canImport(UIKit)
/// iOS's own in-app browser, presented modally over whatever is showing, as
/// Apple asks `SFSafariViewController` to be. Its Done button and edge swipe
/// close it again.
enum SafariSheet {
    @MainActor
    static func present(_ url: URL) {
        // It only takes web pages; anything else still goes to its own app.
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let presenter = topViewController()
        else {
            OpenExternally.open(url)
            return
        }
        presenter.present(SFSafariViewController(url: url), animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
#else
enum SafariSheet {
    @MainActor
    static func present(_ url: URL) { OpenExternally.open(url) }
}
#endif

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
import SafariServices
#endif

#if DEBUG
#Preview {
    PreviewHost { model in
        BrowseView(model: model)
    }
    .frame(minWidth: 600, minHeight: 500)
}
#endif

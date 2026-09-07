import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

/// The content canvas. Browsing and preview occupy the same space: opening an
/// object replaces the grid rather than stacking a window on top of it.
struct BrowseView: View {
    @Bindable var model: LibraryModel
    /// Where the canvas actually drew each item, which is what tells an arrow
    /// key what "the row above" means in a layout that is not a uniform grid.
    @State private var itemFrames = GalleryFrames<CanvasItemID>()
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isCanvasFocused: Bool

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
        .toolbar { GalleryToolbar(model: model) }
        .searchable(text: $model.searchText, tokens: $model.searchTokens, prompt: searchPrompt) { token in
            Label(token.name, systemImage: token.symbolName)
        }
        .searchFocused($isSearchFocused)
        .onChange(of: model.searchFieldFocusRequests) { isSearchFocused = true }
        .onChange(of: isSearchFocused) { _, focused in model.isTextEntryFocused = focused }
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
                        items
                            // Named on the content rather than the scroll view,
                            // so an item's measured frame describes where it
                            // sits in the canvas and does not change as the
                            // canvas scrolls.
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
                    .onChange(of: model.contents) {
                        itemFrames.keep(Set(model.canvasOrder))
                    }
                }
            }
        }
        .modifier(GalleryDropTarget(model: model))
    }

    /// One arrangement for all three view modes: what differs between a grid,
    /// a masonry wall and a list is the layout and the card, and both of those
    /// are decided in `Gallery`.
    private var items: some View {
        GalleryLayout(mode: model.viewMode, scale: model.itemScale) {
            ForEach(model.canvasItems) { item in
                switch item {
                case .folder(let folder):
                    let isCursor = model.cursor == .folder(folder.id)
                    FolderItemView(folder: folder, mode: model.viewMode,
                                   peeks: model.folderPeeks[folder.id] ?? [],
                                   isCursor: isCursor, scale: model.itemScale) {
                        model.scope = .folder(folder.id)
                    }
                    .draggable(FolderTransfer(id: folder.id))
                    .modifier(FolderDropTarget(model: model, folder: folder))
                    .galleryItem(CanvasItemID.folder(folder.id),
                                 isCursor: isCursor,
                                 mode: model.viewMode,
                                 radius: model.viewMode.folderCornerRadius,
                                 in: canvasCoordinateSpace,
                                 frames: itemFrames)
                case .object(let object):
                    let isSelected = model.selection.contains(object.id)
                    let isCursor = model.cursor == .object(object.id)
                    ObjectItemView(object: object, mode: model.viewMode,
                                   isSelected: isSelected, isCursor: isCursor,
                                   scale: model.itemScale)
                    .modifier(ObjectItemBehavior(
                        model: model,
                        object: object,
                        isSelected: isSelected,
                        select: { model.select(object.id, modifiers: $0) },
                        open: { model.openObject(object) }
                    ))
                    .galleryItem(CanvasItemID.object(object.id),
                                 isCursor: isCursor,
                                 mode: model.viewMode,
                                 radius: model.viewMode.itemCornerRadius,
                                 in: canvasCoordinateSpace,
                                 frames: itemFrames)
                }
            }
        }
        .padding(model.viewMode.contentInsets)
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

    // MARK: Actions

    /// Puts the keyboard where the model says it belongs.
    private func syncFocus() {
        isCanvasFocused = model.keyboardPane == .canvas
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

/// The open folder and Inbox are real storage destinations. Dropping on empty
/// canvas space is therefore a useful move, while collections, tags and other
/// read-only scopes should not pretend to be folders.
private struct CanvasObjectDropTarget: ViewModifier {
    let model: LibraryModel

    private var destination: FolderID? {
        switch model.scope {
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

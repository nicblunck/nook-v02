import CoreGraphics
import SwiftUI
import NookLibrary

/// Driving the canvas from the keyboard.
///
/// Selection policy lives here rather than in the views so that a click and an
/// arrow key reach the same rules: the pointer and the keyboard are two ways
/// of saying the same thing, and only one of them should have an opinion about
/// what shift means.
@MainActor
extension LibraryModel {

    // MARK: Reading the canvas

    var canvasOrder: [CanvasItemID] { canvasItems.map(\.itemID) }

    var cursorObject: ObjectSnapshot? {
        guard case .object(let id) = cursor else { return nil }
        return contents.objects.first { $0.id == id }
    }

    var cursorFolder: FolderSnapshot? {
        guard case .folder(let id) = cursor else { return nil }
        return contents.folders.first { $0.id == id }
    }

    // MARK: Moving

    /// Moves the cursor one step, taking the selection with it.
    ///
    /// `frames` is what the canvas measured; it decides what "up" means in a
    /// layout that is not a uniform grid.
    /// Returns whether the cursor actually went anywhere, so a key that has
    /// run out of canvas can do something else with itself.
    @discardableResult
    func moveCursor(
        _ direction: CanvasDirection,
        extendingSelection: Bool = false,
        frames: [CanvasItemID: CGRect] = [:]
    ) -> Bool {
        let order = canvasOrder
        guard let target = CanvasNavigation.destination(
            from: cursor, direction: direction, order: order, frames: frames
        ) else { return false }
        place(target, extendingSelection: extendingSelection)
        return true
    }

    /// Home and End: the top of the canvas and the bottom of it.
    func moveCursorToEdge(_ direction: CanvasDirection, extendingSelection: Bool = false) {
        guard let target = CanvasNavigation.edge(direction, in: canvasOrder) else { return }
        place(target, extendingSelection: extendingSelection)
    }

    private func place(_ target: CanvasItemID, extendingSelection: Bool) {
        cursor = target

        guard let id = target.objectID else {
            // The cursor has come to rest on a folder. Extending a selection
            // steps over it rather than through it, because a place cannot be
            // part of a selection the batch actions will be handed.
            if !extendingSelection {
                selection = []
                selectionAnchor = nil
            }
            return
        }

        if extendingSelection {
            let anchor = selectionAnchor ?? id
            selectionAnchor = anchor
            selection = objectRange(from: anchor, to: id)
        } else {
            selectionAnchor = id
            selection = [id]
        }
    }

    // MARK: Selection

    /// One selection policy, whichever input asked for it.
    func select(_ id: ObjectID, modifiers: EventModifiers) {
        // Clicking an item is another way of saying the keyboard belongs to
        // the canvas.
        focus(.canvas)
        cursor = .object(id)

        if modifiers.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            selectionAnchor = id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor ?? selection.first {
            selectionAnchor = anchor
            selection.formUnion(objectRange(from: anchor, to: id))
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    /// Clicking a folder is another way of saying the keyboard belongs to
    /// the canvas — the same thing clicking an object says. A folder never
    /// joins a selection of objects, the rule an arrow key that lands on one
    /// already follows, so this always clears whatever was selected and
    /// rests the cursor here rather than trying to make sense of a modifier.
    func selectFolder(_ id: FolderID, modifiers: EventModifiers = []) {
        focus(.canvas)
        cursor = .folder(id)
        selection = []
        selectionAnchor = nil
    }

    /// Every object between two others, in the order the destination on
    /// screen reads.
    func objectRange(from anchor: ObjectID, to target: ObjectID) -> Set<ObjectID> {
        let ids = visibleObjects.map(\.id)
        guard let start = ids.firstIndex(of: anchor), let end = ids.firstIndex(of: target) else {
            return [target]
        }
        return Set(ids[min(start, end)...max(start, end)])
    }

    // MARK: Opening

    /// Return, and the Open command: enter a folder, or open a thing.
    func openCursorItem() {
        switch cursor {
        case .folder(let id):
            // The same step clicking a folder takes, so history records it the
            // same way.
            scope = .folder(id)
        case .object(let id):
            guard let object = contents.objects.first(where: { $0.id == id }) else { return }
            openObject(object)
        case nil:
            break
        }
    }

    /// Opening a thing. A link points at the live web rather than at stored
    /// content, so it opens where the user's browsing actually happens.
    ///
    /// A locked object is a door before it is a thing. Authenticating replaces
    /// the redacted snapshot with a whole one, so what finally opens is read
    /// from the canvas again rather than from the one that arrived without its
    /// address or its bytes.
    func openObject(_ object: ObjectSnapshot) {
        cursor = .object(object.id)
        open(object) { [self] opened in
            selection = [opened.id]
            selectionAnchor = opened.id
        }
    }

    /// `selecting` is how the gallery underneath names what was opened — the
    /// canvas names an object, Home names the tile that was clicked — and runs
    /// only once something is actually shown, so a link that opens in the
    /// browser changes no selection.
    private func open(_ object: ObjectSnapshot,
                      selecting select: @escaping (ObjectSnapshot) -> Void) {
        guard object.isLocked else {
            reveal(object, selecting: select)
            return
        }
        Task {
            guard await unlock(object, named: object.title),
                  let unlocked = visibleObjects.first(where: { $0.id == object.id })
            else { return }
            reveal(unlocked, selecting: select)
        }
    }

    private func reveal(_ object: ObjectSnapshot,
                        selecting select: (ObjectSnapshot) -> Void) {
        if object.kind == .link, let url = object.sourceURL {
            OpenExternally.open(url)
            return
        }
        select(object)
        previewedObjectID = object.id
    }

    /// Space: Quick Look, as everywhere else on the Mac.
    ///
    /// A folder has nothing to preview, and a link has no stored content to
    /// show, so on either the key does nothing rather than opening something
    /// the user did not ask for.
    func previewCursorItem() {
        guard let object = cursorObject, object.kind != .link else { return }
        guard !object.isLocked else {
            openObject(object)
            return
        }
        selection = [object.id]
        selectionAnchor = object.id
        previewedObjectID = object.id
    }

    var canOpenCursorItem: Bool { cursor != nil && previewedObjectID == nil }

    var canQuickLookCursorItem: Bool {
        guard previewedObjectID == nil, let object = cursorObject else { return false }
        return object.kind != .link
    }

    // MARK: Either gallery
    //
    // The menu bar acts on whatever the window is showing, so Open and Quick
    // Look are asked for once here rather than by two commands that would
    // have to agree.

    var canOpenCurrentItem: Bool {
        canOpenCursorItem
    }

    func openCurrentItem() {
        openCursorItem()
    }

    var canQuickLookCurrentItem: Bool {
        canQuickLookCursorItem
    }

    func previewCurrentItem() {
        previewCursorItem()
    }

    // MARK: The sidebar

    /// The folder the sidebar is pointing at, if it is pointing at one.
    private var sidebarFolder: FolderSnapshot? {
        guard let id = currentFolderID else { return nil }
        return allFolders.first { $0.folder.id == id }?.folder
    }

    /// Right opens a closed folder, and on anything with nothing left to open
    /// hands the keyboard to the canvas — which is where you were heading
    /// anyway.
    func expandOrEnterCanvas() {
        guard let folder = sidebarFolder,
              folder.subfolderCount > 0,
              !expandedFolders.contains(folder.id)
        else {
            enterCanvas()
            return
        }
        expandedFolders.insert(folder.id)
    }

    /// Left closes an open folder, and on one that is already closed goes to
    /// the folder above it — the outline convention, and the only way back up
    /// a deep tree without reading every row on the way.
    func collapseOrGoToParent() {
        guard let folder = sidebarFolder else { return }
        if folder.subfolderCount > 0, expandedFolders.contains(folder.id) {
            expandedFolders.remove(folder.id)
            return
        }
        // A top-level folder has no row above it to climb to: the sections
        // around it are other kinds of place, not its parent.
        guard let parent = folder.parentID else { return }
        navigate(to: .scope(.folder(parent)))
    }

    /// Arriving from the sidebar has to land on something. Stepping across
    /// into an empty canvas, or one with nothing lit, looks exactly like the
    /// key having done nothing.
    func lightFirstItemIfNothingIsLit() {
        guard cursor == nil else { return }
        moveCursor(.down)
    }

    // MARK: Going up

    /// The folder containing this one, which is not the same as going back:
    /// Back retraces where the user has been, this climbs the tree.
    var enclosingDestination: LibraryDestination? {
        guard !isShowingHome, case .folder = scope, !breadcrumbs.isEmpty else { return nil }
        // `folderPath` ends with the folder itself, so its parent is the one
        // before it — and a root folder's parent is the library.
        if breadcrumbs.count >= 2 {
            return .scope(.folder(breadcrumbs[breadcrumbs.count - 2].id))
        }
        return .home
    }

    var canGoToEnclosingScope: Bool { enclosingDestination != nil && !isTypingText }

    func goToEnclosingScope() {
        guard let target = enclosingDestination else { return }
        let leaving = currentFolderID
        navigate(to: target)
        // Arriving from below, the cursor rests on the folder just left, so
        // the way back down is one key press.
        if let leaving { cursor = .folder(leaving) }
    }
}

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
    func moveCursor(
        _ direction: CanvasDirection,
        extendingSelection: Bool = false,
        frames: [CanvasItemID: CGRect] = [:]
    ) {
        let order = canvasOrder
        guard let target = CanvasNavigation.destination(
            from: cursor, direction: direction, order: order, frames: frames
        ) else { return }
        place(target, extendingSelection: extendingSelection)
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

    /// Every object between two others, in the order the canvas is sorted.
    func objectRange(from anchor: ObjectID, to target: ObjectID) -> Set<ObjectID> {
        let ids = contents.objects.map(\.id)
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
    func openObject(_ object: ObjectSnapshot) {
        cursor = .object(object.id)
        if object.kind == .link, let url = object.sourceURL {
            OpenExternally.open(url)
            return
        }
        selection = [object.id]
        selectionAnchor = object.id
        previewedObjectID = object.id
    }

    /// Space: Quick Look, as everywhere else on the Mac.
    ///
    /// A folder has nothing to preview, and a link has no stored content to
    /// show, so on either the key does nothing rather than opening something
    /// the user did not ask for.
    func previewCursorItem() {
        guard let object = cursorObject, object.kind != .link else { return }
        selection = [object.id]
        selectionAnchor = object.id
        previewedObjectID = object.id
    }

    var canOpenCursorItem: Bool { cursor != nil && previewedObjectID == nil }

    var canQuickLookCursorItem: Bool {
        guard previewedObjectID == nil, let object = cursorObject else { return false }
        return object.kind != .link
    }

    // MARK: Going up

    /// The folder containing this one, which is not the same as going back:
    /// Back retraces where the user has been, this climbs the tree.
    var enclosingScope: LibraryScope? {
        guard case .folder = scope, !breadcrumbs.isEmpty else { return nil }
        // `folderPath` ends with the folder itself, so its parent is the one
        // before it — and a root folder's parent is the library.
        if breadcrumbs.count >= 2 { return .folder(breadcrumbs[breadcrumbs.count - 2].id) }
        return .allObjects
    }

    var canGoToEnclosingScope: Bool { enclosingScope != nil && !isTypingText }

    func goToEnclosingScope() {
        guard let target = enclosingScope else { return }
        let leaving = currentFolderID
        navigate(to: .scope(target))
        // Arriving from below, the cursor rests on the folder just left, so
        // the way back down is one key press.
        if let leaving { cursor = .folder(leaving) }
    }
}

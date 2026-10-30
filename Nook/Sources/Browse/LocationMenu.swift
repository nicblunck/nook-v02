import SwiftUI
import NookLibrary

/// The actions available on a place itself, rather than on anything inside
/// it — what a right click (or, on iOS, a long press) on empty canvas space
/// offers. The same vocabulary the toolbar's Import menu and the menu bar
/// already offer everywhere, just reachable without leaving the mouse.
struct LocationMenu: View {
    let model: LibraryModel

    var body: some View {
        Button("New Folder…", systemImage: "folder.badge.plus") {
            model.editingAppearance = .newFolder(parent: model.currentFolderID)
        }
        Button("New Collection…", systemImage: "rectangle.stack.badge.plus") {
            model.editingAppearance = .newCollection(adding: [])
        }
        Button("New Tag…", systemImage: "tag") {
            model.editingAppearance = .newTag()
        }
        Divider()
        Button("Import Files…", systemImage: "folder") {
            model.isImporterPresented = true
        }
        Button("Import from Photos…", systemImage: "photo.on.rectangle") {
            model.isPhotosPickerPresented = true
        }
        Button("Add URL…", systemImage: "link.badge.plus") {
            model.isAddURLPresented = true
        }
        Button("Paste", systemImage: "doc.on.clipboard") {
            Task { await model.importPasteboard() }
        }
    }
}

/// Pin or unpin a place as a card at the top of the sidebar. Pinning is
/// offered greyed out once all the card slots are taken, so it is clear why
/// it can't be done rather than missing.
struct PinMenuItem: View {
    let settings: AppSettings
    let place: PinnedPlace

    var body: some View {
        if settings.isPinned(place) {
            Button("Unpin from Top", systemImage: "pin.slash") { settings.unpin(place) }
        } else {
            Button("Pin to Top", systemImage: "pin") { settings.pin(place) }
                .disabled(!settings.canPinMore)
        }
    }
}

/// Every kind of capture the library takes, as menu items: what the
/// "Add Something" button in an empty place opens. Each one lands wherever
/// the canvas currently is, the same as the add bar's.
struct AddContentMenu: View {
    let model: LibraryModel

    var body: some View {
        #if os(macOS)
        Button("Add from Files…", systemImage: "doc") {
            model.isImporterPresented = true
        }
        Button("Scan Document…", systemImage: "doc.viewfinder") {
            ContinuityCameraScanner.scan(for: model)
        }
        Button("Add Photo…", systemImage: "photo.on.rectangle") {
            model.isPhotosPickerPresented = true
        }
        #else
        Button("Add File…", systemImage: "doc") {
            model.isImporterPresented = true
        }
        Button("Scan Document…", systemImage: "doc.viewfinder") {
            model.isDocumentScannerPresented = true
        }
        Button("Add Photo…", systemImage: "photo.on.rectangle") {
            model.isPhotosPickerPresented = true
        }
        Button("Take Photo…", systemImage: "camera") {
            model.isCameraPresented = true
        }
        #endif
        Button("Add URL…", systemImage: "link.badge.plus") {
            model.isAddURLPresented = true
        }
        Button("Paste", systemImage: "doc.on.clipboard") {
            Task { await model.importPasteboard() }
        }
    }
}

/// The actions available on one folder — the canvas's equivalent of
/// `ObjectMenu`, offered wherever a folder is drawn: the sidebar, the canvas,
/// and the compact library list on iOS.
struct FolderMenu: View {
    let model: LibraryModel
    let folder: FolderSnapshot
    /// Only the caller knows how "open" is drawn — the canvas replaces itself,
    /// the compact list pushes a new screen.
    let open: () -> Void

    var body: some View {
        Button("Open", systemImage: "folder") { open() }
        Divider()
        if folder.isInTrash {
            // In the Trash a folder can only come back or go for good.
            Button("Put Back", systemImage: "arrow.uturn.backward") {
                Task { await model.restoreFolder(folder.id) }
            }
            Button("Delete Immediately…", systemImage: "trash.slash", role: .destructive) {
                model.requestDeleteImmediately(folder)
            }
        } else {
            liveActions
        }
    }

    @ViewBuilder
    private var liveActions: some View {
        Button("Rename…", systemImage: "pencil") {
            model.namingPrompt = .renameFolder(folder.id)
        }
        Button("New Subfolder…", systemImage: "folder.badge.plus") {
            model.editingAppearance = .newFolder(parent: folder.id)
        }
        Button("Customize…", systemImage: "paintpalette") {
            model.editingAppearance = AppearanceTarget(
                reference: .folder(folder.id), title: folder.name, appearance: folder.appearance
            )
        }
        PinMenuItem(settings: model.settings, place: .folder(folder.id))
        Divider()
        // Hiding a subfolder that only inherited Hidden from an ancestor
        // marks it explicitly and, the same as hiding anything else, moves it
        // to Hidden's own top level — so this doubles as how a nested folder
        // gets promoted out from under whatever it was nested in.
        privacyMenuItems(for: folder,
                         hide: { await model.setHidden($0, forFolder: folder) },
                         lock: { await model.setLocked($0, forFolder: folder) },
                         lockNow: folder.isLockOpen ? { await model.relockFolders() } : nil)
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            model.requestMoveToTrash(folder)
        }
    }
}

/// Hide and Lock as a pair of menu items, offered on what the place is in its
/// own right — a subfolder of a hidden folder is hidden without being hidden
/// itself, and only the ancestor can lift that. Shared by the sidebar and the
/// canvas so the two never drift apart on what these buttons say or do. Only
/// a folder can lock, so this pair is folder-only; collections get the
/// hide-only sibling below.
@MainActor
@ViewBuilder
///
/// "Remove Lock" takes the lock off for good. Closing an open locked folder
/// for now is "Lock Now", offered only while it is open, so neither word is
/// ever asked to mean the other.
func privacyMenuItems(for item: some PrivacyBearing,
                      hide: @escaping (Bool) async -> Void,
                      lock: @escaping (Bool) async -> Void,
                      lockNow: (() async -> Void)? = nil) -> some View {
    hideMenuItem(for: item, hide: hide)
    if let lockNow {
        Button("Lock Now", systemImage: "lock.fill") {
            Task { await lockNow() }
        }
    }
    Button(item.isExplicitlyLocked ? "Remove Lock" : "Lock",
           systemImage: item.isExplicitlyLocked ? "lock.slash" : "lock") {
        Task { await lock(!item.isExplicitlyLocked) }
    }
}

/// Hide alone, for entities — collections — that can be hidden but never
/// locked.
@MainActor
@ViewBuilder
func hideMenuItem(for item: some PrivacyBearing,
                  hide: @escaping (Bool) async -> Void) -> some View {
    Button(item.isExplicitlyHidden ? "Unhide" : "Hide",
           systemImage: item.isExplicitlyHidden ? "eye" : "eye.slash") {
        Task { await hide(!item.isExplicitlyHidden) }
    }
}

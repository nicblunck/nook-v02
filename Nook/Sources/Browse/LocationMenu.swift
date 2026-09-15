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
        Divider()
        // Hiding a subfolder that only inherited Hidden from an ancestor
        // marks it explicitly and, the same as hiding anything else, moves it
        // to Hidden's own top level — so this doubles as how a nested folder
        // gets promoted out from under whatever it was nested in.
        privacyMenuItems(for: folder,
                         hide: { await model.setHidden($0, forFolder: folder) },
                         lock: { await model.setLocked($0, forFolder: folder) })
        Divider()
        Button("Delete Folder", systemImage: "trash", role: .destructive) {
            Task { await model.deleteFolder(folder.id) }
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
func privacyMenuItems(for item: some PrivacyBearing,
                      hide: @escaping (Bool) async -> Void,
                      lock: @escaping (Bool) async -> Void) -> some View {
    hideMenuItem(for: item, hide: hide)
    Button(item.isExplicitlyLocked ? "Unlock" : "Lock",
           systemImage: item.isExplicitlyLocked ? "lock.open" : "lock") {
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

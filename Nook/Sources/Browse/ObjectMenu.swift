import SwiftUI
import NookLibrary

/// The actions available on one or more objects, shared by the context menu
/// and the preview toolbar so both offer the same vocabulary.
struct ObjectMenu: View {
    let model: LibraryModel
    let objects: [ObjectSnapshot]
    /// Puts the selection on the item this menu was opened from. Only the
    /// gallery that drew it knows how to name it — the canvas names an object,
    /// Home names one of the tiles showing it — and preview, which is already
    /// showing one thing, has nothing to name.
    var select: (() -> Void)?

    private var ids: [ObjectID] { objects.map(\.id) }

    var body: some View {
        if model.isShowingDeleted {
            Button("Put Back", systemImage: "arrow.uturn.backward") {
                Task { await model.restore(ids) }
            }
            Button("Delete Immediately…", systemImage: "trash.slash", role: .destructive) {
                model.requestDeleteImmediately(objects)
            }
        } else {
            if objects.count == 1, let object = objects.first {
                Button("Open", systemImage: "eye") {
                    model.previewedObjectID = object.id
                }
                Button("Get Info", systemImage: "info.circle") {
                    select?()
                    model.setInspector(true)
                }
                Divider()
            }

            Button(favoriteTitle, systemImage: shouldFavorite ? "star" : "star.slash") {
                Task { await model.setFavorite(shouldFavorite, for: ids) }
            }

            Menu("Move To", systemImage: "folder") {
                Button("Inbox") { Task { await model.move(ids, to: nil) } }
                if !model.allFolders.isEmpty {
                    Divider()
                    ForEach(model.allFolders, id: \.folder.id) { entry in
                        Button(String(repeating: "   ", count: entry.depth) + entry.folder.name) {
                            Task { await model.move(ids, to: entry.folder.id) }
                        }
                    }
                }
            }

            // Adding to a collection never changes where an object lives, which
            // is why this is a separate action from Move To rather than a mode
            // of it.
            Menu("Add to Collection", systemImage: "rectangle.stack.badge.plus") {
                // The prompt is the window's, so this offers the same thing
                // from the canvas, from Home and from inside preview.
                Button("New Collection…") {
                    model.editingAppearance = .newCollection(adding: ids)
                }
                if !model.collections.isEmpty { Divider() }
                ForEach(model.collections) { collection in
                    Button(collection.name) {
                        Task { await model.addToCollection(collection.id, objects: ids) }
                    }
                }
            }

            Menu("Tags", systemImage: "tag") {
                Button("New Tag…") {
                    model.editingAppearance = .newTag(adding: ids)
                }
                if !model.tags.isEmpty {
                    Divider()
                    ForEach(model.tags) { tag in
                        let isAppliedToAll = objects.allSatisfy { object in
                            object.tags.contains { $0.id == tag.id }
                        }
                        Button {
                            if isAppliedToAll {
                                Task { await model.removeTag(tag.id, from: ids) }
                            } else {
                                Task { await model.addTag(tag.name, to: ids) }
                            }
                        } label: {
                            Label(tag.name, systemImage: isAppliedToAll ? "checkmark" : "plus")
                        }
                    }
                }
            }

            if !model.isShowingHome, case .collection(let id) = model.scope {
                Button("Remove from Collection", systemImage: "minus.circle") {
                    Task { await model.removeFromCollection(id, objects: ids) }
                }
            }

            let urls = model.outgoingURLs(for: objects)
            if !urls.isEmpty {
                ShareLink(items: urls) {
                    Label(urls.count == 1 ? "Share Original" : "Share \(urls.count) Originals",
                          systemImage: "square.and.arrow.up")
                }
                Button(urls.count == 1 ? "Export Original…" : "Export \(urls.count) Originals…",
                       systemImage: "square.and.arrow.down") {
                    model.beginExport(of: objects)
                }
            }

            Divider()

            // Hiding asks for Face ID, Touch ID or the passcode before
            // anything moves — including on the way back out. Objects
            // themselves can't be locked; only the folder they live in can.
            Button(hideTitle, systemImage: shouldHide ? "eye.slash" : "eye") {
                Task { await model.setHidden(shouldHide, for: objects) }
            }

            Divider()

            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                model.requestMoveToTrash(objects)
            }
        }
    }

    private var shouldFavorite: Bool { !objects.allSatisfy(\.isFavorite) }

    private var favoriteTitle: String {
        shouldFavorite ? (objects.count == 1 ? "Favorite" : "Favorite \(objects.count) Items")
                       : (objects.count == 1 ? "Remove Favorite" : "Remove Favorites")
    }

    // What this offers is decided by what the objects are in their own right.
    // An object inside a hidden folder is hidden without being hidden itself,
    // and an Unhide there would promise something it cannot deliver: only the
    // folder can lift what the folder imposed.
    private var shouldHide: Bool { !objects.allSatisfy(\.isExplicitlyHidden) }

    private var hideTitle: String {
        title(shouldHide ? "Hide" : "Unhide")
    }

    private func title(_ verb: String) -> String {
        objects.count == 1 ? verb : "\(verb) \(objects.count) Items"
    }
}

/// The actions for whatever is selected, folders included.
///
/// A selection of objects alone gets the full object menu, and a single
/// folder its own menu. Once folders and objects are chosen together — or
/// several folders — only what suits all of them is offered: moving, hiding
/// and the Trash. Favourites, tags, collections and sharing belong to objects,
/// and offering them on a selection that is partly folders would promise more
/// than they do.
struct SelectionMenu: View {
    let model: LibraryModel
    let objects: [ObjectSnapshot]
    let folders: [FolderSnapshot]

    var body: some View {
        if folders.isEmpty {
            ObjectMenu(model: model, objects: objects)
        } else if objects.isEmpty, folders.count == 1, let folder = folders.first {
            FolderMenu(model: model, folder: folder) {
                Task { await model.openFolder(folder.id) }
            }
        } else if model.isShowingDeleted {
            Button("Put Back", systemImage: "arrow.uturn.backward") {
                Task { await model.restore(objects: objectIDs, folders: folderIDs) }
            }
            Button("Delete Immediately…", systemImage: "trash.slash", role: .destructive) {
                model.requestDeleteImmediately(objects: objects, folders: folders)
            }
        } else {
            Menu("Move To", systemImage: "folder") {
                // A folder's way out of every other folder is the top level;
                // an object's is the Inbox. With both chosen there is no one
                // name for "out", so only folders are offered.
                if objects.isEmpty {
                    Button("Top Level") { move(to: nil) }
                    if !model.allFolders.isEmpty { Divider() }
                }
                ForEach(model.allFolders, id: \.folder.id) { entry in
                    Button(String(repeating: "   ", count: entry.depth) + entry.folder.name) {
                        move(to: entry.folder.id)
                    }
                    // Nothing moves inside itself.
                    .disabled(!folders.allSatisfy { model.folderCanBeDropped($0.id, into: entry.folder.id) })
                }
            }

            Divider()

            Button(shouldHide ? "Hide \(count) Items" : "Unhide \(count) Items",
                   systemImage: shouldHide ? "eye.slash" : "eye") {
                let hide = shouldHide
                Task {
                    await model.setHidden(hide, for: objects)
                    for folder in folders { await model.setHidden(hide, forFolder: folder) }
                }
            }

            Divider()

            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                model.requestMoveToTrash(objects: objects, folders: folders)
            }
        }
    }

    private var objectIDs: [ObjectID] { objects.map(\.id) }
    private var folderIDs: [FolderID] { folders.map(\.id) }
    private var count: Int { objects.count + folders.count }

    private var shouldHide: Bool {
        !(objects.allSatisfy(\.isExplicitlyHidden) && folders.allSatisfy(\.isExplicitlyHidden))
    }

    private func move(to destination: FolderID?) {
        Task { await model.move(objects: objectIDs, folders: folderIDs, to: destination) }
    }
}

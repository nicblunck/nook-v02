import SwiftUI
import NookLibrary

/// The actions available on one or more objects, shared by the context menu
/// and the preview toolbar so both offer the same vocabulary.
struct ObjectMenu: View {
    let model: LibraryModel
    let objects: [ObjectSnapshot]
    var newCollection: (([ObjectID]) -> Void)?

    private var ids: [ObjectID] { objects.map(\.id) }
    private var isDeletedScope: Bool { model.scope == .recentlyDeleted }

    var body: some View {
        if isDeletedScope {
            Button("Put Back", systemImage: "arrow.uturn.backward") {
                Task { await model.restore(ids) }
            }
            Button("Delete Immediately…", systemImage: "trash.slash", role: .destructive) {
                Task { await model.permanentlyDelete(ids) }
            }
        } else {
            if objects.count == 1, let object = objects.first {
                Button("Open", systemImage: "eye") {
                    model.previewedObjectID = object.id
                }
                Button("Get Info", systemImage: "info.circle") {
                    model.selection = [object.id]
                    model.isInspectorPresented = true
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
                if let newCollection {
                    Button("New Collection…") { newCollection(ids) }
                    if !model.collections.isEmpty { Divider() }
                }
                ForEach(model.collections) { collection in
                    Button(collection.name) {
                        Task { await model.addToCollection(collection.id, objects: ids) }
                    }
                }
            }

            if !model.tags.isEmpty {
                Menu("Tags", systemImage: "tag") {
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

            if case .collection(let id) = model.scope {
                Button("Remove from Collection", systemImage: "minus.circle") {
                    Task { await model.removeFromCollection(id, objects: ids) }
                }
            }

            let urls = model.localURLs(for: objects)
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

            // Hiding and locking each ask for Face ID, Touch ID or the
            // passcode before anything moves — including on the way back out.
            Button(hideTitle, systemImage: shouldHide ? "eye.slash" : "eye") {
                Task { await model.setHidden(shouldHide, for: objects) }
            }
            Button(lockTitle, systemImage: shouldLock ? "lock" : "lock.open") {
                Task { await model.setLocked(shouldLock, for: objects) }
            }

            Divider()

            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await model.delete(ids) }
            }
        }
    }

    private var shouldFavorite: Bool { !objects.allSatisfy(\.isFavorite) }

    private var favoriteTitle: String {
        shouldFavorite ? (objects.count == 1 ? "Favorite" : "Favorite \(objects.count) Items")
                       : (objects.count == 1 ? "Remove Favorite" : "Remove Favorites")
    }

    // What these offer is decided by what the objects are in their own right.
    // An object inside a hidden folder is hidden without being hidden itself,
    // and an Unhide there would promise something it cannot deliver: only the
    // folder can lift what the folder imposed.
    private var shouldHide: Bool { !objects.allSatisfy(\.isExplicitlyHidden) }
    private var shouldLock: Bool { !objects.allSatisfy(\.isExplicitlyLocked) }

    private var hideTitle: String {
        title(shouldHide ? "Hide" : "Unhide")
    }

    private var lockTitle: String {
        title(shouldLock ? "Lock" : "Unlock")
    }

    private func title(_ verb: String) -> String {
        objects.count == 1 ? verb : "\(verb) \(objects.count) Items"
    }
}

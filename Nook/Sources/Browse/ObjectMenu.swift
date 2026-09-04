import SwiftUI
import NookLibrary

/// The actions available on one or more objects, shared by the context menu
/// and the preview toolbar so both offer the same vocabulary.
struct ObjectMenu: View {
    let model: LibraryModel
    let objects: [ObjectSnapshot]

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
}

import SwiftUI
import NookLibrary

/// The scope pill shown in the search field.
///
/// Searching inside a location scopes the query there automatically; the pill
/// makes that visible and, crucially, removable — deleting it runs the same
/// query against the whole library rather than starting a new search.
struct SearchScopeToken: Identifiable, Hashable {
    let scope: LibraryScope
    let name: String
    let symbolName: String

    var id: LibraryScope { scope }

    @MainActor
    init?(scope: LibraryScope, model: LibraryModel) {
        switch scope {
        case .allObjects:
            return nil
        case .folder(let id), .folderTree(let id):
            guard let folder = model.allFolders.first(where: { $0.folder.id == id })?.folder else {
                return nil
            }
            self.init(scope: scope, name: folder.name,
                      symbolName: folder.appearance.symbolName ?? "folder")
        case .collection(let id):
            guard let collection = model.collections.first(where: { $0.id == id }) else { return nil }
            self.init(scope: scope, name: collection.name,
                      symbolName: collection.appearance.symbolName ?? "rectangle.stack")
        case .tag(let id):
            guard let tag = model.tags.first(where: { $0.id == id }) else { return nil }
            self.init(scope: scope, name: tag.name, symbolName: "tag")
        case .kind(let kind):
            self.init(scope: scope, name: kind.pluralDisplayName, symbolName: kind.symbolName)
        case .inbox:
            self.init(scope: scope, name: "Inbox", symbolName: "tray")
        case .favorites:
            self.init(scope: scope, name: "Favorites", symbolName: "star")
        case .recent:
            self.init(scope: scope, name: "Recent", symbolName: "clock")
        case .recentlyDeleted:
            self.init(scope: scope, name: "Recently Deleted", symbolName: "trash")
        case .hidden:
            self.init(scope: scope, name: "Hidden", symbolName: "eye.slash")
        }
    }

    private init(scope: LibraryScope, name: String, symbolName: String) {
        self.scope = scope
        self.name = name
        self.symbolName = symbolName
    }
}

/// The rename and create prompts the app can raise, from the sidebar or the
/// menu bar.
enum NamingPrompt: Identifiable {
    case newFolder(parent: FolderID?)
    case renameFolder(FolderID)
    /// The objects the new collection should gather, which is empty when the
    /// prompt was raised from the menu bar or the sidebar rather than from a
    /// selection.
    case newCollection(adding: [ObjectID])
    case renameCollection(CollectionID)
    case renameTag(TagID)

    var id: String {
        switch self {
        case .newFolder(let parent): "newFolder-\(parent?.description ?? "root")"
        case .renameFolder(let id): "renameFolder-\(id)"
        case .newCollection(let adding):
            "newCollection-" + adding.map { $0.uuid.uuidString }.joined(separator: ",")
        case .renameCollection(let id): "renameCollection-\(id)"
        case .renameTag(let id): "renameTag-\(id)"
        }
    }

    var title: String {
        switch self {
        case .newFolder: "New Folder"
        case .renameFolder: "Rename Folder"
        case .newCollection: "New Collection"
        case .renameCollection: "Rename Collection"
        case .renameTag: "Rename Tag"
        }
    }

    var confirmTitle: String {
        switch self {
        case .newFolder, .newCollection: "Create"
        default: "Rename"
        }
    }

    var message: String? {
        switch self {
        case .newFolder(let parent):
            parent == nil ? "At the top level of your library." : "Inside the selected folder."
        case .newCollection:
            "Collections gather items from anywhere without moving them."
        default:
            nil
        }
    }
}

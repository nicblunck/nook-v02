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
        case .trash:
            self.init(scope: scope, name: "Trash", symbolName: "trash")
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

/// The lightweight rename prompts the app can raise. New folders, collections
/// and tags use `AppearanceTarget` so naming and styling happen together.
enum NamingPrompt: Identifiable {
    case renameFolder(FolderID)
    case renameCollection(CollectionID)
    case renameTag(TagID)

    var id: String {
        switch self {
        case .renameFolder(let id): "renameFolder-\(id)"
        case .renameCollection(let id): "renameCollection-\(id)"
        case .renameTag(let id): "renameTag-\(id)"
        }
    }

    var title: String {
        switch self {
        case .renameFolder: "Rename Folder"
        case .renameCollection: "Rename Collection"
        case .renameTag: "Rename Tag"
        }
    }

    var confirmTitle: String {
        "Rename"
    }

    var message: String? {
        nil
    }
}

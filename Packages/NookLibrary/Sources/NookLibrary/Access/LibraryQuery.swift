import Foundation

/// Where a query looks.
///
/// Scopes are views over one object store, not separate storage areas — which
/// is why the same query type serves the sidebar, the canvas, scoped search,
/// global search, App Intents and the MCP adapter.
public enum LibraryScope: Hashable, Sendable {
    /// Everything live in the library.
    case allObjects
    /// Loose objects at the root. Folders at the root are not included.
    case inbox
    case recent
    case favorites
    case recentlyDeleted
    /// Everything the user has put out of sight.
    ///
    /// Hidden is a place rather than a filter over the library: a hidden thing
    /// lives here and is absent everywhere else, authenticated or not. That is
    /// what keeps an open Hidden session from quietly repopulating Inbox,
    /// Recent, search and every other surface with content the user hid.
    case hidden
    /// The immediate contents of one folder.
    case folder(FolderID)
    /// A folder and everything beneath it. Used when search descends a subtree.
    case folderTree(FolderID)
    case collection(CollectionID)
    case tag(TagID)
    case kind(ObjectKind)

    public var displayName: String {
        switch self {
        case .allObjects: "All"
        case .inbox: "Inbox"
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .recentlyDeleted: "Recently Deleted"
        case .hidden: "Hidden"
        case .folder, .folderTree: "Folder"
        case .collection: "Collection"
        case .tag: "Tag"
        case .kind(let kind): kind.pluralDisplayName
        }
    }

    /// Whether this scope reads from Recently Deleted rather than the live library.
    public var showsDeleted: Bool { self == .recentlyDeleted }
}

public enum ObjectSortField: String, Codable, Sendable, CaseIterable, Identifiable {
    case name
    case dateAdded
    case dateCreated
    case kind
    case size

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: "Name"
        case .dateAdded: "Date Added"
        case .dateCreated: "Date Created"
        case .kind: "Type"
        case .size: "Size"
        }
    }
}

public struct ObjectSort: Hashable, Sendable, Codable {
    public var field: ObjectSortField
    public var ascending: Bool

    public static let `default` = ObjectSort(field: .dateAdded, ascending: false)

    public init(field: ObjectSortField, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }
}

/// One request against the library.
///
/// Browsing and searching are the same operation with different arguments,
/// which is what stops the search UI, Siri and MCP from growing separate — and
/// separately wrong — query and privacy logic.
public struct ObjectQuery: Hashable, Sendable {
    public var scope: LibraryScope
    /// Free text matched against title, filename, notes, tag names, source URL and domain.
    public var searchText: String
    /// Narrows to these kinds when non-empty.
    public var kinds: Set<ObjectKind>
    public var favoritesOnly: Bool
    public var sort: ObjectSort
    public var limit: Int?

    public init(
        scope: LibraryScope = .allObjects,
        searchText: String = "",
        kinds: Set<ObjectKind> = [],
        favoritesOnly: Bool = false,
        sort: ObjectSort = .default,
        limit: Int? = nil
    ) {
        self.scope = scope
        self.searchText = searchText
        self.kinds = kinds
        self.favoritesOnly = favoritesOnly
        self.sort = sort
        self.limit = limit
    }

    public var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasSearchText: Bool { !trimmedSearchText.isEmpty }
}

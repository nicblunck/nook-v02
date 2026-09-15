import AppIntents
import Foundation
import NookLibrary

/// Search the library from Siri, Shortcuts or Spotlight.
///
/// Runs without opening the app and returns entities, so a shortcut can pass
/// the results on to something else. It reads through the same query API the
/// interface uses, under the standard access context — hidden content, and
/// anything inside a locked folder, is not discoverable here at all.
struct SearchLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Library"
    static let description = IntentDescription(
        "Finds items in your library by title, filename, notes, tags, folder or link.",
        categoryName: "Finding"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Search For", requestValueDialog: "What are you looking for?")
    var query: String

    @Parameter(title: "Media Type")
    var mediaType: MediaTypeAppEnum?

    @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 100))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query) in my library") {
            \.$mediaType
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ObjectEntity]> {
        let service = try await LibraryAccess.service()
        let kinds: Set<ObjectKind> = mediaType.map { [$0.kind] } ?? []
        let results = await service.objects(
            matching: ObjectQuery(searchText: query, kinds: kinds, limit: limit)
        )
        return .result(value: results.map(ObjectEntity.init))
    }
}

/// Lists what is in a folder without opening the app.
struct FindObjectsInFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Items in Folder"
    static let description = IntentDescription("Lists the items in a folder.", categoryName: "Finding")
    static let openAppWhenRun = false

    @Parameter(title: "Folder")
    var folder: FolderEntity

    @Parameter(title: "Include Subfolders", default: false)
    var includeSubfolders: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Find items in \(\.$folder)") { \.$includeSubfolders }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ObjectEntity]> {
        guard let id = folder.folderID else { return .result(value: []) }
        let service = try await LibraryAccess.service()
        let scope: LibraryScope = includeSubfolders ? .folderTree(id) : .folder(id)
        let results = await service.objects(matching: ObjectQuery(scope: scope))
        return .result(value: results.map(ObjectEntity.init))
    }
}

/// Lists everything carrying a tag.
struct ShowObjectsWithTagIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Items with Tag"
    static let description = IntentDescription("Shows the items carrying a tag.", categoryName: "Finding")
    static let openAppWhenRun = true

    @Parameter(title: "Tag")
    var tag: TagEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show my items tagged \(\.$tag)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = tag.tagID else { return .result() }
        AppNavigator.shared.request(.scope(.tag(id)))
        return .result()
    }
}

struct ShowMediaTypeIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Media Type"
    static let description = IntentDescription("Shows one kind of item.", categoryName: "Finding")
    static let openAppWhenRun = true

    @Parameter(title: "Media Type")
    var mediaType: MediaTypeAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Show my \(\.$mediaType)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppNavigator.shared.request(.scope(.kind(mediaType.kind)))
        return .result()
    }
}

struct OpenObjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Item"
    static let description = IntentDescription("Opens an item in Nook.", categoryName: "Opening")
    static let openAppWhenRun = true

    @Parameter(title: "Item")
    var object: ObjectEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$object)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = object.objectID else { return .result() }
        AppNavigator.shared.request(.object(id))
        return .result()
    }
}

struct OpenFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Folder"
    static let description = IntentDescription("Opens a folder in Nook.", categoryName: "Opening")
    static let openAppWhenRun = true

    @Parameter(title: "Folder")
    var folder: FolderEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$folder)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = folder.folderID else { return .result() }
        AppNavigator.shared.request(.scope(.folder(id)))
        return .result()
    }
}

struct OpenCollectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Collection"
    static let description = IntentDescription("Opens a collection in Nook.", categoryName: "Opening")
    static let openAppWhenRun = true

    @Parameter(title: "Collection")
    var collection: CollectionEntity

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$collection)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = collection.collectionID else { return .result() }
        AppNavigator.shared.request(.scope(.collection(id)))
        return .result()
    }
}

/// The phrases Siri recognises without the user building a shortcut first.
struct NookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchLibraryIntent(),
            // Only entity and enum parameters may appear in a phrase, so the
            // free-text query is asked for rather than spoken inline.
            phrases: [
                "Search \(.applicationName)",
                "Search my \(.applicationName) library",
                "Find something in \(.applicationName)"
            ],
            shortTitle: "Search Library",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: ShowObjectsWithTagIntent(),
            phrases: [
                "Show my \(\.$tag) in \(.applicationName)",
                "Open \(\.$tag) tag in \(.applicationName)"
            ],
            shortTitle: "Show Tag",
            systemImageName: "tag"
        )
        AppShortcut(
            intent: OpenCollectionIntent(),
            phrases: [
                "Open \(\.$collection) in \(.applicationName)",
                "Open my \(\.$collection) collection in \(.applicationName)"
            ],
            shortTitle: "Open Collection",
            systemImageName: "rectangle.stack"
        )
        AppShortcut(
            intent: ShowMediaTypeIntent(),
            phrases: [
                "Show my \(\.$mediaType) in \(.applicationName)"
            ],
            shortTitle: "Show Media Type",
            systemImageName: "square.grid.2x2"
        )
    }
}

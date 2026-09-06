import AppIntents
import Foundation
import NookLibrary

/// The library's entities as the system understands them.
///
/// Siri, Spotlight, Shortcuts and Apple Intelligence all address content
/// through these. They resolve by durable id, so a shortcut still points at the
/// same item after a rename or a move, and every lookup goes through
/// `LibraryService` with the standard access context — meaning hidden content
/// is never offered to the system, and a locked item arrives already redacted.
struct ObjectEntity: AppEntity, Identifiable {
    let id: String
    let title: String
    let kind: String
    let location: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Item", numericFormat: "\(placeholder: .int) items"
    )

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(kind) in \(location)")
    }

    static let defaultQuery = ObjectEntityQuery()

    init(_ snapshot: ObjectSnapshot) {
        id = snapshot.id.uuid.uuidString
        title = snapshot.title
        kind = snapshot.kind.displayName
        location = snapshot.folderName ?? "Inbox"
    }

    var objectID: ObjectID? { ObjectID(uuidString: id) }
}

struct ObjectEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ObjectEntity] {
        let service = try await LibraryAccess.service()
        return await withTaskGroup(of: ObjectEntity?.self) { group in
            for identifier in identifiers {
                group.addTask {
                    guard let id = ObjectID(uuidString: identifier) else { return nil }
                    return await service.object(id).map(ObjectEntity.init)
                }
            }
            var found: [ObjectEntity] = []
            for await entity in group { if let entity { found.append(entity) } }
            return found
        }
    }

    /// Backs "find my …" phrasing, using the same metadata search the app uses.
    func entities(matching string: String) async throws -> [ObjectEntity] {
        let service = try await LibraryAccess.service()
        return await service
            .objects(matching: ObjectQuery(searchText: string, limit: 30))
            .map(ObjectEntity.init)
    }

    func suggestedEntities() async throws -> [ObjectEntity] {
        let service = try await LibraryAccess.service()
        return await service
            .objects(matching: ObjectQuery(scope: .recent, limit: 10))
            .map(ObjectEntity.init)
    }
}

struct FolderEntity: AppEntity, Identifiable {
    let id: String
    let name: String
    let itemCount: Int

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Folder", numericFormat: "\(placeholder: .int) folders"
    )

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: "\(itemCount) \(itemCount == 1 ? "item" : "items")")
    }

    static let defaultQuery = FolderEntityQuery()

    init(_ snapshot: FolderSnapshot) {
        id = snapshot.id.uuid.uuidString
        name = snapshot.name
        itemCount = snapshot.objectCount
    }

    var folderID: FolderID? { FolderID(uuidString: id) }
}

struct FolderEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FolderEntity] {
        let service = try await LibraryAccess.service()
        var found: [FolderEntity] = []
        for identifier in identifiers {
            guard let id = FolderID(uuidString: identifier) else { continue }
            if let folder = await service.folder(id) { found.append(FolderEntity(folder)) }
        }
        return found
    }

    func entities(matching string: String) async throws -> [FolderEntity] {
        try await allFolders().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [FolderEntity] {
        try await allFolders()
    }

    private func allFolders() async throws -> [FolderEntity] {
        let service = try await LibraryAccess.service()
        var result: [FolderEntity] = []
        var queue = await service.rootFolders()
        while !queue.isEmpty {
            let folder = queue.removeFirst()
            result.append(FolderEntity(folder))
            queue.append(contentsOf: await service.subfolders(of: folder.id))
        }
        return result
    }
}

struct CollectionEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Collection", numericFormat: "\(placeholder: .int) collections"
    )

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static let defaultQuery = CollectionEntityQuery()

    init(_ snapshot: CollectionSnapshot) {
        id = snapshot.id.uuid.uuidString
        name = snapshot.name
    }

    var collectionID: CollectionID? { CollectionID(uuidString: id) }
}

struct CollectionEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CollectionEntity] {
        let wanted = Set(identifiers)
        return try await all().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [CollectionEntity] {
        try await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [CollectionEntity] { try await all() }

    private func all() async throws -> [CollectionEntity] {
        let service = try await LibraryAccess.service()
        return await service.collections().map(CollectionEntity.init)
    }
}

struct TagEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Tag", numericFormat: "\(placeholder: .int) tags"
    )

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static let defaultQuery = TagEntityQuery()

    init(_ snapshot: TagSnapshot) {
        id = snapshot.id.uuid.uuidString
        name = snapshot.name
    }

    var tagID: TagID? { TagID(uuidString: id) }
}

struct TagEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TagEntity] {
        let wanted = Set(identifiers)
        return try await all().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [TagEntity] {
        try await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [TagEntity] { try await all() }

    private func all() async throws -> [TagEntity] {
        let service = try await LibraryAccess.service()
        return await service.tags().map(TagEntity.init)
    }
}

/// Media types as a choosable option, so "show me my PDFs" resolves without a
/// free-text guess.
enum MediaTypeAppEnum: String, AppEnum {
    case images, videos, audio, pdfs, links, screenshots

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Media Type")

    static let caseDisplayRepresentations: [MediaTypeAppEnum: DisplayRepresentation] = [
        .images: "Images",
        .videos: "Videos",
        .audio: "Audio",
        .pdfs: "PDFs",
        .links: "Links",
        .screenshots: "Screenshots"
    ]

    var kind: ObjectKind {
        switch self {
        case .images: .image
        case .videos: .video
        case .audio: .audio
        case .pdfs: .pdf
        case .links: .link
        case .screenshots: .screenshot
        }
    }
}

/// Where intents get the library.
///
/// An intent may run when the app is not, so it opens the library itself
/// rather than reaching for app state. Everything it can see is whatever the
/// standard, unauthenticated access context permits.
enum LibraryAccess {
    static func service() async throws -> LibraryService {
        try await SharedLibrary.shared.current().service
    }
}

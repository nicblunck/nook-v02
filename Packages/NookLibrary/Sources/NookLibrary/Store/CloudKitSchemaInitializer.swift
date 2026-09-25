#if DEBUG
import CoreData
import Foundation
import SwiftData

/// Pushes every record type and field of `LibrarySchema` into the CloudKit
/// Development environment, so it can then be deployed to Production.
///
/// SwiftData only creates a field in CloudKit when a record carrying it syncs,
/// so a field no Debug build has ever uploaded is missing from Development,
/// deploying leaves it out of Production, and every export that touches it is
/// refused there. This is Apple's documented remedy for SwiftData: mirror the
/// same model through NSPersistentCloudKitContainer and initialize its schema.
///
/// Runs against a throwaway store, never the user's library, and only in Debug
/// builds, which are the ones signed for the Development environment.
public enum CloudKitSchemaInitializer {
    public static func initializeDevelopmentSchema(
        containerIdentifier: String = Library.defaultCloudKitContainerIdentifier
    ) throws {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: LibrarySchema.models) else {
            throw CocoaError(.coreData)
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NookSchema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let description = NSPersistentStoreDescription(url: directory.appending(path: "Schema.store"))
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: containerIdentifier
        )
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentCloudKitContainer(name: "NookSchema", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: (any Error)?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        try container.initializeCloudKitSchema()

        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}
#endif

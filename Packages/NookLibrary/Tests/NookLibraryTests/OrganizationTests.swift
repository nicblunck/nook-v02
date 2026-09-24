import Foundation
import Testing
@testable import NookLibrary

@Suite("Organization")
struct OrganizationTests {

    @Test("Removing an object from a collection leaves the object where it lives")
    func collectionRemovalIsNotDeletion() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "Work")
        let source = try harness.makeSourceFile(named: "brief.txt", contents: "brief")
        let report = await harness.service.importItems([.file(url: source)], into: .folder(folder.id))
        let id = try #require(report.importedIDs.first)

        let collection = try await harness.service.createCollection(named: "Pitch")
        try await harness.service.addObjects([id], toCollection: collection.id)
        #expect(await harness.service.objects(matching: ObjectQuery(scope: .collection(collection.id))).count == 1)

        try await harness.service.removeObjects([id], fromCollection: collection.id)

        #expect(await harness.service.objects(matching: ObjectQuery(scope: .collection(collection.id))).isEmpty)
        let object = try #require(await harness.service.object(id))
        #expect(object.folderID == folder.id)
    }

    @Test("Deleting is reversible for the retention window, then reclaims its bytes")
    func deletionLifecycle() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "Drafts")
        let source = try harness.makeSourceFile(named: "draft.txt", contents: "draft")
        let report = await harness.service.importItems([.file(url: source)], into: .folder(folder.id))
        let id = try #require(report.importedIDs.first)
        let descriptor = try #require(await harness.service.object(id)?.blob)

        try await harness.service.delete([id])
        #expect(await harness.service.objects(matching: ObjectQuery(scope: .allObjects)).isEmpty)
        #expect(await harness.service.objects(matching: ObjectQuery(scope: .trash)).count == 1)
        // Still in the Trash, so the bytes must survive a collection pass.
        try await harness.service.collectOrphanedBlobs()
        #expect(harness.library.blobStore.isAvailableLocally(descriptor))

        try await harness.service.restore([id])
        #expect(await harness.service.objects(matching: ObjectQuery(scope: .allObjects)).count == 1)

        try await harness.service.permanentlyDelete([id])
        #expect(harness.library.blobStore.isAvailableLocally(descriptor) == false)
    }

    @Test("A folder goes to the Trash whole, and comes back whole to where it was")
    func folderTrashRoundTrip() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }
        let service = harness.service

        let work = try await service.createFolder(named: "Work")
        let taxes = try await service.createFolder(named: "Taxes", in: work.id)
        let receipts = try await service.createFolder(named: "Receipts", in: taxes.id)
        let source = try harness.makeSourceFile(named: "receipt.txt", contents: "receipt")
        let report = await service.importItems([.file(url: source)], into: .folder(receipts.id))
        let id = try #require(report.importedIDs.first)

        try await service.moveFolderToTrash(taxes.id)

        // Gone from the library…
        #expect(await service.subfolders(of: work.id).isEmpty)
        #expect(await service.objects(matching: ObjectQuery(scope: .allObjects)).isEmpty)
        #expect(await service.objectCount(in: .allObjects) == 0)
        // …and in the Trash as one folder, not as its loose contents.
        let trash = await service.contents(of: .trash)
        #expect(trash.folders.map(\.id) == [taxes.id])
        #expect(trash.objects.isEmpty)
        #expect(await service.objectCount(in: .trash) == 1)
        // Opening it there shows what it held.
        #expect(await service.contents(of: .folder(taxes.id)).folders.map(\.id) == [receipts.id])
        #expect(await service.contents(of: .folder(receipts.id)).objects.map(\.id) == [id])
        #expect(await service.object(id)?.isInTrash == true)

        try await service.restoreFolders([taxes.id])

        #expect(await service.subfolders(of: work.id).map(\.id) == [taxes.id])
        #expect(await service.object(id)?.folderID == receipts.id)
        #expect(await service.contents(of: .trash).isEmpty)
    }

    @Test("Something put back from inside a folder still in the Trash lands at the top")
    func putBackFromInsideATrashedFolder() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }
        let service = harness.service

        let taxes = try await service.createFolder(named: "Taxes")
        let old = try await service.createFolder(named: "2019", in: taxes.id)
        let source = try harness.makeSourceFile(named: "return.txt", contents: "return")
        let report = await service.importItems([.file(url: source)], into: .folder(taxes.id))
        let id = try #require(report.importedIDs.first)

        try await service.moveFolderToTrash(taxes.id)
        try await service.restore([id])
        try await service.restoreFolders([old.id])

        #expect(await service.object(id)?.folderID == nil)
        #expect(await service.object(id)?.isInTrash == false)
        #expect(await service.rootFolders().map(\.id) == [old.id])
    }

    @Test("A hidden folder leaves hiding for the Trash and goes back into it")
    func hiddenFolderTrashRoundTrip() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }
        let service = harness.service

        let diary = try await service.createFolder(named: "Diary")
        try await service.setPrivacy(PrivacyFlags(isHidden: true, isLocked: false), forFolder: diary.id)

        try await service.moveFolderToTrash(diary.id)
        #expect(await service.contents(of: .trash).folders.map(\.id) == [diary.id])

        try await service.restoreFolders([diary.id])
        #expect(await service.folder(diary.id, in: .standard) == nil)
        #expect(await service.contents(of: .trash).isEmpty)
    }

    @Test("Emptying the Trash deletes what was in its folders too, and nothing live")
    func emptyTrashTakesFolderContents() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }
        let service = harness.service

        let taxes = try await service.createFolder(named: "Taxes")
        let inside = try harness.makeSourceFile(named: "inside.txt", contents: "inside")
        let loose = try harness.makeSourceFile(named: "loose.txt", contents: "loose")
        let kept = try harness.makeSourceFile(named: "kept.txt", contents: "kept")
        let insideID = try #require(await service.importItems([.file(url: inside)], into: .folder(taxes.id)).importedIDs.first)
        let ids = await service.importItems([.file(url: loose), .file(url: kept)], into: .root).importedIDs
        let insideBlob = try #require(await service.object(insideID)?.blob)

        try await service.moveFolderToTrash(taxes.id)
        try await service.delete([ids[0]])
        try await service.emptyTrash()

        #expect(await service.contents(of: .trash).isEmpty)
        #expect(await service.folder(taxes.id) == nil)
        #expect(await service.object(insideID) == nil)
        #expect(await service.objects(matching: ObjectQuery(scope: .allObjects)).map(\.id) == [ids[1]])
        #expect(harness.library.blobStore.isAvailableLocally(insideBlob) == false)
    }

    @Test("Shared bytes outlive the first object to be deleted")
    func sharedBlobSurvivesOneDeletion() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let first = try harness.makeSourceFile(named: "a.txt", contents: "shared")
        let second = try harness.makeSourceFile(named: "b.txt", contents: "shared")
        let report = await harness.service.importItems([.file(url: first), .file(url: second)], into: .root)
        let ids = report.importedIDs
        #expect(ids.count == 2)
        let descriptor = try #require(await harness.service.object(ids[0])?.blob)

        try await harness.service.permanentlyDelete([ids[0]])
        #expect(harness.library.blobStore.isAvailableLocally(descriptor))

        try await harness.service.permanentlyDelete([ids[1]])
        #expect(harness.library.blobStore.isAvailableLocally(descriptor) == false)
    }

    @Test("A folder cannot be moved inside itself")
    func folderMoveGuard() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let parent = try await harness.service.createFolder(named: "Parent")
        let child = try await harness.service.createFolder(named: "Child", in: parent.id)

        await #expect(throws: LibraryError.self) {
            try await harness.service.moveFolder(parent.id, to: child.id)
        }
    }

    @Test("Tags are matched case-insensitively rather than duplicated")
    func tagsNormalize() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "poster.txt", contents: "poster")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)

        try await harness.service.addTag(named: "Typography", to: [id])
        try await harness.service.addTag(named: "typography ", to: [id])

        #expect(await harness.service.tags().count == 1)
        #expect(try #require(await harness.service.object(id)).tags.count == 1)
    }

    @Test("Folders, collections and standalone tags keep their staged appearance")
    func styledEntityCreation() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folderAppearance = EntityAppearance(colorHex: "#FF9500", symbolName: "book.fill")
        let collectionAppearance = EntityAppearance(colorHex: "#AF52DE", emoji: "✨")
        let tagAppearance = EntityAppearance(colorHex: "#34C759", symbolName: "leaf.fill")

        let folder = try await harness.service.createFolder(
            named: "Reading",
            appearance: folderAppearance
        )
        let collection = try await harness.service.createCollection(
            named: "Inspiration",
            appearance: collectionAppearance
        )
        let tag = try await harness.service.createTag(
            named: "Growing",
            appearance: tagAppearance
        )

        #expect(folder.appearance == folderAppearance)
        #expect(collection.appearance == collectionAppearance)
        #expect(tag.appearance == tagAppearance)
        #expect(await harness.service.tags().contains { $0.id == tag.id && $0.objectCount == 0 })
    }

    @Test("The shared customization save updates name and appearance together")
    func entityCustomization() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "Drafts")
        let collection = try await harness.service.createCollection(named: "Maybe")
        let tag = try await harness.service.createTag(named: "Old")
        let appearance = EntityAppearance(colorHex: "#007AFF", emoji: "🧭")

        try await harness.service.updateFolder(folder.id, name: "Trips", appearance: appearance)
        try await harness.service.updateCollection(collection.id, name: "Places", appearance: appearance)
        try await harness.service.updateTag(tag.id, name: "Travel", appearance: appearance)

        let updatedFolder = try #require(await harness.service.folder(folder.id))
        let updatedCollection = try #require(
            await harness.service.collections().first { $0.id == collection.id }
        )
        let updatedTag = try #require(await harness.service.tags().first { $0.id == tag.id })

        #expect(updatedFolder.name == "Trips")
        #expect(updatedFolder.appearance == appearance)
        #expect(updatedCollection.name == "Places")
        #expect(updatedCollection.appearance == appearance)
        #expect(updatedTag.name == "Travel")
        #expect(updatedTag.appearance == appearance)
    }
}

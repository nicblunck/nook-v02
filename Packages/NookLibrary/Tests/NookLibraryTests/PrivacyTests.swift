import Foundation
import Testing
@testable import NookLibrary

@Suite("Privacy")
struct PrivacyTests {

    @Test("A hidden folder removes its descendants from every discovery surface")
    func hiddenFolderInheritsDownward() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let parent = try await harness.service.createFolder(named: "Private")
        let child = try await harness.service.createFolder(named: "Deeper", in: parent.id)
        let source = try harness.makeSourceFile(named: "secret.txt", contents: "secret")
        let report = await harness.service.importItems([.file(url: source)], into: .folder(child.id))
        let id = try #require(report.importedIDs.first)

        // Visible before the parent is hidden.
        #expect(await harness.service.object(id) != nil)

        try await harness.service.setPrivacy(PrivacyFlags(isHidden: true), forFolder: parent.id)

        // Gone from the object's own folder, from the library-wide view, from
        // search, and from a direct lookup by id.
        #expect(await harness.service.object(id) == nil)
        #expect(await harness.service.objects(matching: ObjectQuery(scope: .folder(child.id))).isEmpty)
        #expect(await harness.service.objects(matching: ObjectQuery(scope: .allObjects)).isEmpty)
        #expect(await harness.service.objects(matching: ObjectQuery(searchText: "secret")).isEmpty)
        #expect(await harness.service.rootFolders().isEmpty)
    }

    @Test("Hidden content reappears only inside an authenticated hidden context")
    func hiddenContextReveals() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "Private")
        let source = try harness.makeSourceFile(named: "secret.txt", contents: "secret")
        await harness.service.importItems([.file(url: source)], into: .folder(folder.id))
        try await harness.service.setPrivacy(PrivacyFlags(isHidden: true), forFolder: folder.id)

        let authenticated = AccessContext().enteringHiddenContext()
        let found = await harness.service.objects(matching: ObjectQuery(scope: .allObjects), in: authenticated)
        #expect(found.count == 1)
    }

    @Test("A locked object still lists, but yields no content and no metadata")
    func lockedObjectIsRedacted() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "taxes.txt", contents: "figures")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)
        try await harness.service.updateObject(id, notes: "sensitive")
        try await harness.service.setPrivacy(PrivacyFlags(isLocked: true), forObjects: [id])

        let object = try #require(await harness.service.object(id))
        #expect(object.visibility.isRedacted)
        #expect(object.title == ObjectSnapshot.lockedPlaceholderTitle)
        #expect(object.notes.isEmpty)
        #expect(object.originalFilename == nil)
        // No blob descriptor means no thumbnail and no preview can be produced.
        #expect(object.blob == nil)

        await #expect(throws: LibraryError.self) {
            _ = try await harness.service.originalURL(for: id)
        }
    }

    @Test("Authenticating the locking folder releases its descendants")
    func unlockingAncestorReleasesDescendants() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "Finances")
        let source = try harness.makeSourceFile(named: "taxes.txt", contents: "figures")
        let report = await harness.service.importItems([.file(url: source)], into: .folder(folder.id))
        let id = try #require(report.importedIDs.first)
        try await harness.service.setPrivacy(PrivacyFlags(isLocked: true), forFolder: folder.id)

        #expect(try #require(await harness.service.object(id)).visibility.isRedacted)

        let authenticated = AccessContext().unlocking(.folder(folder.id))
        let released = try #require(await harness.service.object(id, in: authenticated))
        #expect(released.visibility == .full)
        #expect(released.title == "taxes")
    }

    @Test("A hidden collection hides its own surface, not the objects in it")
    func collectionPrivacyIsSurfaceOnly() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "reference.txt", contents: "reference")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)

        let collection = try await harness.service.createCollection(named: "Mood")
        try await harness.service.addObjects([id], toCollection: collection.id)

        let collections = await harness.service.collections()
        #expect(collections.count == 1)

        try await harness.service.setPrivacy(PrivacyFlags(isHidden: true), forCollection: collection.id)

        // The collection is gone from the sidebar...
        #expect(await harness.service.collections().isEmpty)
        // ...but the object is untouched where it actually lives.
        #expect(await harness.service.object(id) != nil)
        #expect(await harness.service.objects(matching: ObjectQuery(scope: .inbox)).count == 1)
        // Knowing the collection identifier still does not make its protected
        // surface readable.
        #expect(await harness.service.objects(
            matching: ObjectQuery(scope: .collection(collection.id))
        ).isEmpty)

        let authenticated = AccessContext().enteringHiddenContext()
        #expect(await harness.service.objects(
            matching: ObjectQuery(scope: .collection(collection.id)),
            in: authenticated
        ).map(\.id) == [id])
    }

    @Test("Navigation counts do not reveal hidden objects")
    func countsRespectPrivacy() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "Private counts")
        let source = try harness.makeSourceFile(named: "hidden.txt", contents: "hidden")
        let report = await harness.service.importItems([.file(url: source)], into: .folder(folder.id))
        let id = try #require(report.importedIDs.first)
        let collection = try await harness.service.createCollection(named: "Counted")
        try await harness.service.addObjects([id], toCollection: collection.id)
        try await harness.service.addTag(named: "Only hidden", to: [id])

        try await harness.service.setPrivacy(PrivacyFlags(isHidden: true), forObjects: [id])

        #expect(try #require(await harness.service.folder(folder.id)).objectCount == 0)
        #expect(try #require(await harness.service.collection(collection.id)).memberCount == 0)
        #expect(try #require(await harness.service.tags().first).objectCount == 0)
    }
}

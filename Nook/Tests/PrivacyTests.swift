import Foundation
import Testing
import NookLibrary
@testable import Nook

/// Hidden and Locked from the app's side.
///
/// The library's own suite already covers what the privacy broker decides.
/// What these check is the half above it: that nothing raises the access
/// context without an answer from the device owner, and that the interface
/// puts content back out of reach when it is done with it.
@MainActor
@Suite("Privacy")
struct PrivacyTests {

    @Test("Hiding puts an item in Hidden, and it is nowhere else")
    func hidingMovesItIntoHidden() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "private.txt"))
        await model.setHidden(true, for: [object])
        #expect(harness.authenticator.wasAsked)
        #expect(model.contents.objects.isEmpty)

        await model.openHidden()
        #expect(model.scope == .hidden)
        #expect(model.contents.objects.map(\.id) == [object.id])

        // Open is one place open, not the library turned transparent: nothing
        // hidden comes back anywhere else, authenticated or not.
        let everything = await model.library.service.objects(
            matching: ObjectQuery(scope: .allObjects), in: model.accessContext
        )
        #expect(everything.isEmpty)
    }

    @Test("Hidden closes behind you")
    func leavingHiddenClosesIt() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "private.txt"))
        await model.setHidden(true, for: [object])
        await model.openHidden()
        #expect(model.isShowingHiddenContent)

        // What leaving the scope runs, and what Back would find if it walked
        // into Hidden again.
        model.navigate(to: .scope(.inbox))
        await model.closeHidden()
        #expect(!model.isShowingHiddenContent)
        #expect(model.contents.objects.isEmpty)
    }

    @Test("Unhiding puts an object back in the folder it came from")
    func unhidingReturnsItToItsFolder() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "kept.txt"))
        await model.createFolder(named: "Work", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)

        await model.setHidden(true, for: [object])
        await model.openHidden()
        let hidden = try #require(model.contents.objects.first)
        await model.setHidden(false, for: [hidden])

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    /// The folder it came from can be gone by the time it comes back — deleted
    /// while it was out of sight, and out of sight is exactly why nobody was
    /// asked about it at the time.
    @Test("An object whose folder was deleted while it was hidden lands in the Inbox")
    func unhidingAfterTheFolderWentLandsInInbox() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "kept.txt"))
        await model.createFolder(named: "Work", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)
        await model.setHidden(true, for: [object])

        await model.deleteFolder(folder.id)

        await model.openHidden()
        let hidden = try #require(model.contents.objects.first)
        #expect(hidden.id == object.id)
        await model.setHidden(false, for: [hidden])

        model.navigate(to: .scope(.inbox))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    @Test("A refused authentication hides nothing and opens nothing")
    func refusedAuthenticationChangesNothing() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "private.txt"))
        harness.authenticator.outcome = .cancelled

        await model.setHidden(true, for: [object])
        #expect(model.contents.objects.map(\.id) == [object.id])

        await model.openHidden()
        #expect(!model.isShowingHiddenContent)
        #expect(model.scope == .inbox)
    }

    /// A locked object stays on the canvas — it is the door the user has to
    /// find — but arrives without its title, its metadata or its bytes.
    @Test("Locking redacts an object where it stands, and unlocking gives it back")
    func locksAndUnlocks() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "secret.txt"))
        await model.setLocked(true, for: [object])

        let locked = try #require(model.contents.objects.first)
        #expect(locked.visibility.isRedacted)
        #expect(locked.title == ObjectSnapshot.lockedPlaceholderTitle)
        #expect(locked.blob == nil)
        #expect(model.localURL(for: locked) == nil)

        #expect(await model.unlock(locked, named: locked.title))
        let unlocked = try #require(model.contents.objects.first)
        #expect(unlocked.visibility == .full)
        #expect(unlocked.originalFilename == "secret.txt")
        #expect(model.localURL(for: unlocked) != nil)
    }

    @Test("A refused unlock leaves the object redacted")
    func refusedUnlockKeepsRedaction() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "secret.txt"))
        await model.setLocked(true, for: [object])
        harness.authenticator.outcome = .cancelled

        let locked = try #require(model.contents.objects.first)
        #expect(await model.unlock(locked, named: locked.title) == false)
        #expect(try #require(model.contents.objects.first).visibility.isRedacted)
    }

    /// Hidden follows the true hierarchy: what a hidden folder holds is hidden
    /// everywhere, and the folder itself moves out of the sidebar's tree and
    /// into Hidden rather than staying in place with a badge on it.
    @Test("A hidden folder moves into Hidden, and takes its contents with it")
    func hiddenFolderMovesIntoHidden() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "inside.txt"))
        await model.createFolder(named: "Personal", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)

        await model.setHidden(true, forFolder: folder)
        #expect(model.folderTree.isEmpty)

        model.navigate(to: .scope(.allObjects))
        await model.refreshContents()
        #expect(model.contents.objects.isEmpty)

        await model.openHidden()
        #expect(model.contents.folders.map(\.id) == [folder.id])
        // Its contents are inside it, where they have always been, rather than
        // spilled into Hidden alongside the folder.
        #expect(model.contents.objects.isEmpty)
        #expect(model.folderTree.isEmpty)

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    /// Collection privacy protects the collection surface. Where the objects
    /// actually live is untouched, which is the whole distinction the spec
    /// draws between storage-hierarchy and collection-surface privacy.
    @Test("A hidden collection conceals itself, not what it gathers")
    func hiddenCollectionKeepsItsMembersVisible() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "gathered.txt"))
        await model.createCollection(named: "Reading", adding: [object.id])
        let collection = try #require(model.collections.first)

        await model.setHidden(true, forCollection: collection)
        #expect(model.collections.isEmpty)
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    /// Everything a lock protects is released by authenticating the folder
    /// that imposes it, rather than object by object underneath it.
    @Test("Unlocking a locked folder releases what it contains")
    func unlockingFolderReleasesDescendants() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "inside.txt"))
        await model.createFolder(named: "Personal", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)
        await model.setLocked(true, forFolder: folder)

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        #expect(model.lockedLocation?.reference == folder.reference)
        #expect(try #require(model.contents.objects.first).visibility.isRedacted)

        await model.unlockCurrentLocation()
        #expect(model.lockedLocation == nil)
        #expect(try #require(model.contents.objects.first).visibility == .full)
    }
}

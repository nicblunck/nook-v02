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

    @Test("Hiding takes an object off the canvas, and showing hidden content brings it back")
    func hidesAndReveals() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "private.txt"))
        await model.setHidden(true, for: [object])
        #expect(harness.authenticator.wasAsked)
        #expect(model.contents.objects.isEmpty)

        await model.showHiddenContent()
        #expect(model.isShowingHiddenContent)
        #expect(model.contents.objects.map(\.id) == [object.id])

        await model.hideHiddenContent()
        #expect(!model.isShowingHiddenContent)
        #expect(model.contents.objects.isEmpty)
    }

    @Test("A refused authentication hides nothing")
    func refusedAuthenticationChangesNothing() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "private.txt"))
        harness.authenticator.outcome = .cancelled

        await model.setHidden(true, for: [object])
        #expect(model.contents.objects.map(\.id) == [object.id])

        await model.showHiddenContent()
        #expect(!model.isShowingHiddenContent)
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
    /// everywhere, including in the flat views that never mention the folder.
    @Test("A hidden folder takes its contents with it")
    func hiddenFolderHidesItsContents() async throws {
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

        await model.showHiddenContent()
        #expect(model.contents.objects.map(\.id) == [object.id])
        #expect(model.folderTree.count == 1)
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

    /// Putting hidden content away has to take the canvas with it: leaving the
    /// user inside a folder they may no longer see would leave the window
    /// pointing at somewhere that no longer exists for them.
    @Test("Leaving hidden content steps out of a hidden folder")
    func leavingHiddenContentRetreats() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        await model.createFolder(named: "Personal", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.setHidden(true, forFolder: folder)

        await model.showHiddenContent()
        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        #expect(model.scope == .folder(folder.id))

        await model.hideHiddenContent()
        #expect(model.scope == .inbox)
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

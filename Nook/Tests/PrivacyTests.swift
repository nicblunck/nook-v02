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
        #expect(!harness.authenticator.wasAsked)
        #expect(model.contents.objects.isEmpty)

        await model.openHidden()
        #expect(model.scope == .hidden)
        #expect(harness.authenticator.wasAsked)
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

        model.navigate(to: .scope(.inbox))
        await model.loadPreferences()
        await model.refreshContents()
        #expect(!model.isShowingHiddenContent)
        #expect(model.contents.objects.isEmpty)
    }

    /// Hidden behaves like a folder: hiding something moves it there, the way
    /// filing an object into any other folder detaches it from wherever it
    /// used to be, rather than marking it in place.
    @Test("Hiding an object detaches it from its folder, and unhiding lands it in the Inbox")
    func hidingDetachesAndUnhidingLandsInInbox() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "kept.txt"))
        await model.createFolder(named: "Work", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)

        await model.setHidden(true, for: [object])
        model.navigate(to: .scope(.folder(folder.id)))
        await model.loadPreferences()
        await model.refreshContents()
        #expect(model.contents.objects.isEmpty)

        await model.openHidden()
        let hidden = try #require(model.contents.objects.first)
        #expect(hidden.id == object.id)

        // It was detached, not filed, so unhiding does not remember "Work" —
        // it surfaces in the Inbox like anything else with no folder.
        await model.setHidden(false, for: [hidden])
        model.navigate(to: .scope(.inbox))
        await model.loadPreferences()
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    /// Deleting a folder still sends what it visibly contains to Recently
    /// Moved to the Trash whole, even when the folder itself is hidden — the
    /// user was looking right at it, inside Hidden, when they chose to. The
    /// Trash is not a hidden place, so the folder comes out of hiding to be
    /// seen there, and goes back into it if it is put back.
    @Test("Moving a hidden folder to the Trash shows it there, contents and all")
    func trashingAHiddenFolderShowsItInTheTrash() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "inside.txt"))
        await model.createFolder(named: "Personal", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)
        await model.setHidden(true, forFolder: folder)

        await model.moveFolderToTrash(folder.id)

        model.navigate(to: .scope(.trash))
        await model.loadPreferences()
        await model.refreshContents()
        #expect(model.contents.folders.map(\.id) == [folder.id])

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        #expect(model.isShowingDeleted)
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
        #expect(model.contents.objects.isEmpty)

        await model.openHidden()
        #expect(!model.isShowingHiddenContent)
        #expect(model.scope == .inbox)
        #expect(model.contents.objects.isEmpty)
    }

    /// Only a folder can be locked. Its contents are wholly absent from the
    /// canvas until it is opened and authenticated — never merely redacted
    /// the way the folder door itself is.
    @Test("Locking a folder excludes its contents everywhere, and unlocking gives them back")
    func locksAndUnlocks() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "secret.txt"))
        await model.createFolder(named: "Secrets", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)
        await model.setLocked(true, forFolder: folder)

        // Absent from an unrelated scope entirely, not merely redacted there.
        model.navigate(to: .scope(.allObjects))
        await model.refreshContents()
        #expect(model.contents.objects.isEmpty)

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        #expect(model.contents.objects.isEmpty)
        #expect(model.lockedLocation?.reference == folder.reference)

        await model.unlockCurrentLocation()
        #expect(model.lockedLocation == nil)
        let unlocked = try #require(model.contents.objects.first)
        #expect(unlocked.visibility == .full)
        #expect(unlocked.originalFilename == "secret.txt")
        #expect(model.localURL(for: unlocked) != nil)
    }

    /// `openFolder` authenticates before navigating, from a scope that has
    /// nothing to do with the folder being opened. Regression coverage for a
    /// bug where authenticating there ran `unlock`'s default post-unlock
    /// refresh while `scope` still pointed at the old place, which made
    /// `closeLockedFolders()` see the brand-new unlock as not covering the
    /// current location and revoke it immediately — so the folder opened
    /// already re-locked despite a successful Face ID prompt.
    @Test("Opening a locked folder from elsewhere leaves it unlocked once you land")
    func openingALockedFolderDoesNotImmediatelyRelockIt() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "secret.txt"))
        await model.createFolder(named: "Secrets", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)
        await model.setLocked(true, forFolder: folder)

        // Starting somewhere unrelated to the folder being opened is exactly
        // what exposed the bug: `unlock`'s refresh ran under the wrong scope.
        model.navigate(to: .scope(.allObjects))
        await model.refreshContents()

        await model.openFolder(folder.id)
        await model.refreshContents()
        #expect(model.scope == .folder(folder.id))
        #expect(model.lockedLocation == nil)
        let unlocked = try #require(model.contents.objects.first)
        #expect(unlocked.visibility == .full)
    }

    @Test("A refused unlock leaves a locked folder's contents excluded")
    func refusedUnlockKeepsFolderExcluded() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "secret.txt"))
        await model.createFolder(named: "Secrets", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)
        await model.setLocked(true, forFolder: folder)
        harness.authenticator.outcome = .cancelled

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        await model.unlockCurrentLocation()
        #expect(model.lockedLocation?.reference == folder.reference)
        #expect(model.contents.objects.isEmpty)
    }

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

        model.navigate(to: .scope(.inbox))
        await model.loadPreferences()
        #expect(!model.isShowingHiddenContent)
    }

    /// A subfolder hidden only because its parent is has no row of its own in
    /// Hidden — it is reached by opening that parent. Hiding it explicitly is
    /// how it gets one: the same "Hide" a subfolder offers anywhere else both
    /// marks it and, because hiding detaches, promotes it out from under its
    /// former parent.
    @Test("Hiding a subfolder nested in a hidden folder promotes it to Hidden's top level")
    func hidingANestedSubfolderPromotesItToHiddenRoot() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        await model.createFolder(named: "Personal", in: nil)
        let parent = try #require(model.folderTree.first?.folder)
        await model.createFolder(named: "Receipts", in: parent.id)
        model.navigate(to: .scope(.folder(parent.id)))
        await model.refreshContents()
        let child = try #require(model.contents.folders.first)

        await model.setHidden(true, forFolder: parent)

        await model.openHidden()
        #expect(model.contents.folders.map(\.id) == [parent.id])

        model.navigate(to: .scope(.folder(parent.id)))
        await model.refreshContents()
        let nested = try #require(model.contents.folders.first { $0.id == child.id })
        await model.setHidden(true, forFolder: nested)

        model.navigate(to: .scope(.hidden))
        await model.loadPreferences()
        await model.refreshContents()
        #expect(Set(model.contents.folders.map(\.id)) == [parent.id, child.id])

        model.navigate(to: .scope(.folder(parent.id)))
        await model.loadPreferences()
        await model.refreshContents()
        #expect(model.contents.folders.isEmpty)
    }

    /// `rehideItems()` — what focus loss triggers — only ever narrows Hidden.
    /// It never touches `unlockedEntities`, so a folder unlocked earlier and
    /// still being browsed stays open across a focus loss; only navigating
    /// away from its subtree re-locks it.
    @Test("Losing focus re-hides Hidden without relocking a folder you're still browsing")
    func focusLossRehidesAndPreservesLocks() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let lockedObject = try #require(try await harness.importFile(named: "locked.txt"))
        await model.createFolder(named: "Secrets", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([lockedObject.id], to: folder.id)
        await model.setLocked(true, forFolder: folder)

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        await model.unlockCurrentLocation()
        #expect(try #require(model.contents.objects.first { $0.id == lockedObject.id }).visibility == .full)

        // Enter Hidden's authenticated state directly, without navigating
        // scope away from the folder — leaving its subtree is what re-locks
        // it, and that is not what focus loss does.
        model.accessContext = model.accessContext.enteringHiddenContext()
        await model.appDidLoseFocus()
        #expect(!model.isShowingHiddenContent)
        #expect(model.scope == .folder(folder.id))

        await model.refreshContents()
        #expect(try #require(model.contents.objects.first { $0.id == lockedObject.id }).visibility == .full)

        model.settings.rehidesWhenAppLosesFocus = false
        await model.openHidden()
        await model.appDidLoseFocus()
        #expect(model.isShowingHiddenContent)
        await model.rehideItems()
    }

    @Test("User activity restarts the hidden reveal timeout")
    func userActivityRestartsHiddenRevealTimeout() async throws {
        let sleeper = HiddenRevealSleepController()
        let harness = try await TestModel { duration in
            try await sleeper.sleep(for: duration)
        }
        defer { harness.cleanUp() }
        let model = harness.model

        await model.openHidden()
        await sleeper.waitUntilStarted(1)
        #expect(model.isShowingHiddenContent)

        model.appDidReceiveUserActivity()
        await sleeper.waitUntilStarted(2)

        // Completing the superseded wait must not hide anything. Only the
        // fresh wait that began at the last interaction owns the deadline.
        await sleeper.resume(0)
        await Task.yield()
        #expect(model.isShowingHiddenContent)

        await sleeper.resume(1)
        for _ in 0..<100 where model.isShowingHiddenContent {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isShowingHiddenContent)
    }

    @Test("Hidden reveal timeout defaults to five minutes")
    func hiddenRevealTimeoutDefaults() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }

        #expect(harness.model.settings.hiddenRevealTimeout == .after5Minutes)
        #expect(harness.model.settings.hiddenRevealTimeout.duration == .seconds(300))
        #expect(HiddenRevealTimeout.never.duration == nil)
        #expect(harness.model.settings.rehidesWhenAppLosesFocus)
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
        #expect(model.contents.objects.isEmpty)

        await model.unlockCurrentLocation()
        #expect(model.lockedLocation == nil)
        #expect(try #require(model.contents.objects.first).visibility == .full)
    }
}

/// A deterministic stand-in for `Task.sleep` that lets the privacy test fire
/// each scheduled deadline independently.
private actor HiddenRevealSleepController {
    private var nextID = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func sleep(for duration: Duration) async throws {
        let id = nextID
        nextID += 1

        await withCheckedContinuation { continuation in
            continuations[id] = continuation
        }
    }

    func waitUntilStarted(_ count: Int) async {
        while nextID < count { await Task.yield() }
    }

    func resume(_ id: Int) {
        continuations.removeValue(forKey: id)?.resume()
    }
}

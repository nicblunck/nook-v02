import Foundation
import Testing
import NookLibrary
@testable import Nook

/// Home as a gallery.
///
/// The point of these is that Home is not a special case: what it shows is
/// arranged by the same preferences, selected by the same rules and acted on
/// by the same batch actions as any folder. Where it differs — its own
/// remembered arrangement, several queries at once — the difference is stated
/// here rather than left to be discovered.
@Suite("Home")
@MainActor
struct HomeGalleryTests {

    private func harness() async throws -> TestModel {
        let harness = try await TestModel()
        harness.model.navigate(to: .scope(.inbox))
        try await harness.importFile(named: "beta.txt", contents: "beta")
        try await harness.importFile(named: "alpha.txt", contents: "alpha")
        try await harness.importFile(named: "gamma.txt", contents: "gamma")
        harness.model.navigate(to: .home)
        await harness.model.loadPreferences()
        await harness.model.refreshHome()
        return harness
    }

    private func inboxSection(_ model: LibraryModel) throws -> HomeSection {
        try #require(model.homeSections.first { $0.scope == .inbox })
    }

    // MARK: Arrangement

    @Test("Home's sections are ordered by the sort the toolbar is showing")
    func sectionsFollowTheSort() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.setSort(ObjectSort(field: .name, ascending: true))
        let ascending = try inboxSection(model).objects.map(\.title)
        #expect(ascending == ascending.sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        await model.setSort(ObjectSort(field: .name, ascending: false))
        let descending = try inboxSection(model).objects.map(\.title)
        #expect(descending == ascending.reversed())
    }

    /// Home is one fixed place rather than a row in the library, so what it
    /// remembers is kept beside the global default — but it is asked for and
    /// given back the same way a folder's is.
    @Test("Home keeps an arrangement of its own, and gives it back on return")
    func homeRemembersItsOwnArrangement() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.canRememberLocation)
        await model.setRememberingLocation(true)
        await model.setViewMode(.list)
        #expect(harness.model.settings.homePreferences?.viewMode == .list)

        model.navigate(to: .scope(.favorites))
        await model.loadPreferences()
        #expect(model.viewMode == model.settings.defaultPreferences.viewMode)

        model.navigate(to: .home)
        await model.loadPreferences()
        #expect(model.viewMode == .list)
    }

    @Test("Forgetting Home's arrangement puts it back on the default")
    func homeCanFollowTheDefaultAgain() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.setRememberingLocation(true)
        await model.setViewMode(.masonry)
        await model.setRememberingLocation(false)
        #expect(model.settings.homePreferences == nil)

        await model.loadPreferences()
        #expect(model.viewMode == model.settings.defaultPreferences.viewMode)
    }

    /// Manual order is a collection's own order. Home is not a collection, and
    /// the scope the canvas was last pointed at does not make it one.
    @Test("Home offers no manual order to sort by")
    func homeHasNoManualOrder() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createCollection(named: "Reading")
        let collection = try #require(model.collections.first { $0.name == "Reading" }?.id)
        model.navigate(to: .scope(.collection(collection)))
        #expect(model.availableSortFields.contains(.manual))

        model.navigate(to: .home)
        #expect(!model.availableSortFields.contains(.manual))
    }

    // MARK: Selection

    /// The selection is what every batch action is handed, so a selection made
    /// on Home has to be one the inspector, the context menu, Delete and
    /// Export can all read.
    @Test("Selecting on Home is a selection the rest of the app can act on")
    func selectionOnHomeIsReadable() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model
        let tile = try #require(model.homeOrder.first)

        model.selectHomeTile(tile, modifiers: [])
        #expect(model.homeSelection == [tile])
        #expect(model.hasSelection)
        #expect(model.selectedObjectIDs == [tile.object])
        #expect(model.selectedObjects.map(\.id) == [tile.object])
        #expect(model.canExport)
    }

    /// The sections are separate places. An object recently imported and still
    /// unsorted is showing in both Inbox and Recent, and clicking it in one is
    /// not clicking it in the other — an object-level selection would light
    /// both tiles and claim something the user never said.
    @Test("Selecting a tile does not light the same object's other tile")
    func selectingOneTileLeavesTheOtherAlone() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model

        // Something showing in two sections at once.
        let shared = try #require(
            model.homeOrder.first { tile in
                model.homeOrder.filter { $0.object == tile.object }.count > 1
            }
        )
        let twin = try #require(
            model.homeOrder.first { $0.object == shared.object && $0.scope != shared.scope }
        )

        model.selectHomeTile(shared, modifiers: [])
        #expect(model.homeSelection == [shared])
        #expect(!model.homeSelection.contains(twin))
        // The batch actions still act on the thing, which is named once.
        #expect(model.selectedObjects.map(\.id) == [shared.object])
    }

    /// Two tiles, one object: the menu that opens on the unselected twin acts
    /// on that one thing rather than on the selection it is not part of.
    @Test("A range never reaches sideways into the same object's other tile")
    func rangesStayInReadingOrder() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model
        let order = model.homeOrder
        let first = try #require(order.first)

        let range = model.homeTileRange(from: first, to: order[1])
        #expect(range == [order[0], order[1]])
    }

    @Test("Shift extends a selection across Home, as it does on the canvas")
    func shiftExtendsOnHome() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model
        let order = model.homeOrder
        try #require(order.count > 2)

        model.selectHomeTile(order[0], modifiers: [])
        model.selectHomeTile(order[2], modifiers: .shift)
        #expect(model.homeSelection == Set(order[0...2]))
    }

    @Test("Command-clicking adds and removes one tile at a time")
    func commandClickTogglesOnHome() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model
        let order = model.homeOrder
        try #require(order.count > 1)

        model.selectHomeTile(order[0], modifiers: [])
        model.selectHomeTile(order[1], modifiers: .command)
        #expect(model.homeSelection == [order[0], order[1]])

        model.selectHomeTile(order[1], modifiers: .command)
        #expect(model.homeSelection == [order[0]])
    }

    @Test("Select All takes what Home is showing")
    func selectAllOnHome() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.canSelectAll)
        model.selectAll()
        // Every tile, in every section — and more tiles than objects, because
        // some things are showing in both.
        #expect(model.homeSelection == Set(model.homeOrder))
        #expect(model.homeSelection.count > model.visibleObjects.count)
        // What the batch actions are handed is still the things, named once.
        #expect(model.selectedObjectIDs == Set(model.visibleObjects.map(\.id)))
    }

    /// Home and the canvas are refreshed together. Each pruning its selection
    /// against its own contents would leave them clearing each other's.
    @Test("Refreshing the canvas leaves Home's selection alone")
    func canvasRefreshKeepsHomeSelection() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model
        let tile = try #require(model.homeOrder.first)

        model.selectHomeTile(tile, modifiers: [])
        await model.refreshContents()
        #expect(model.homeSelection == [tile])
    }

    @Test("Home lets go of a selected item that has been deleted")
    func homeReleasesDeletedSelection() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model
        let tile = try #require(model.homeOrder.first)

        model.selectHomeTile(tile, modifiers: [])
        await model.delete([tile.object])
        #expect(!model.homeSelection.contains(tile))
        #expect(model.homeSelectionAnchor == nil)
    }

    // MARK: Opening

    /// Preview replaces Home the way it replaces the canvas, and Home's own
    /// objects are what next and previous walk, so opening does not have to
    /// send the user to the section's scope first.
    @Test("Opening from Home opens in place")
    func openingStaysOnHome() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model
        let tile = try #require(model.homeOrder.first)

        model.openHomeTile(tile)
        #expect(model.isShowingHome)
        #expect(model.previewedObjectID == tile.object)
        #expect(model.previewedObject?.id == tile.object)
        #expect(model.homeSelection == [tile])
    }

    @Test("Next and previous walk what Home is showing")
    func previewStepsThroughHome() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model
        let objects = model.visibleObjects
        try #require(objects.count > 1)

        let first = try #require(model.homeOrder.first)
        model.openHomeTile(first)
        model.stepPreview(1)
        #expect(model.previewedObjectID == objects[1].id)
        // The selection follows preview, and stays in the section it started
        // in rather than jumping to the object's other tile.
        #expect(model.homeSelection.count == 1)
        #expect(model.homeSelection.first?.scope == first.scope)
    }

    // MARK: Import

    /// Home is not a place things go into, so importing from it must not fall
    /// through to whichever folder the canvas was last pointed at.
    @Test("Importing from Home lands in the Inbox")
    func importFromHomeGoesToTheInbox() async throws {
        let harness = try await harness()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Papers", in: nil)
        let folder = try #require(model.allFolders.first { $0.folder.name == "Papers" }?.folder.id)
        model.navigate(to: .scope(.folder(folder)))
        await model.refreshContents()
        try await harness.importFile(named: "filed.txt", contents: "filed")
        #expect(model.contents.objects.contains { $0.originalFilename == "filed.txt" })

        model.navigate(to: .home)
        try await harness.importFile(named: "loose.txt", contents: "loose")
        await model.refreshHome()

        let loose = try #require(
            model.visibleObjects.first { $0.originalFilename == "loose.txt" }
        )
        #expect(loose.folderID == nil)
    }
}

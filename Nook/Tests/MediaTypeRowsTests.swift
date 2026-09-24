import Foundation
import Testing
import UniformTypeIdentifiers
import NookLibrary
@testable import Nook

/// The Media Types section names what the library holds, not what it could
/// hold, so an empty library shows none of them.
@MainActor
@Suite("Media type rows")
struct MediaTypeRowsTests {

    @Test("A library with nothing in it lists no media types")
    func emptyLibraryListsNone() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }

        await harness.model.refreshAll()
        #expect(harness.model.mediaTypes.isEmpty)
    }

    @Test("Only the kinds the library actually holds are listed")
    func listsWhatIsThere() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }

        try await harness.importFile(named: "shot.png", as: .png)
        #expect(harness.model.mediaTypes == [.image])
    }

    /// Files are the catch-all kind and have never had a row of their own.
    @Test("Importing a plain file adds no row")
    func plainFileAddsNoRow() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }

        try await harness.importFile(named: "notes.txt")
        #expect(harness.model.mediaTypes.isEmpty)
    }

    @Test("Deleting the last of a kind takes its row away")
    func lastOfAKindRemovesTheRow() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        let image = try #require(try await harness.importFile(named: "shot.png", as: .png))
        #expect(model.mediaTypes == [.image])

        await model.moveToTrash([image.id])
        #expect(model.mediaTypes.isEmpty)
    }

    /// Deleting the last image while looking at Images would otherwise leave
    /// the canvas somewhere the sidebar no longer names.
    @Test("The kind being viewed keeps its row")
    func theOpenKindStays() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        let image = try #require(try await harness.importFile(named: "shot.png", as: .png))
        model.navigate(to: .scope(.kind(.image)))
        await model.moveToTrash([image.id])

        #expect(model.mediaTypes == [.image])
        #expect(model.destination == .scope(.kind(.image)))
    }

    @Test("A media type that has emptied is taken out of the history")
    func emptiedKindLeavesTheHistory() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        let image = try #require(try await harness.importFile(named: "shot.png", as: .png))
        model.navigate(to: .scope(.kind(.image)))
        model.navigate(to: .scope(.inbox))

        await model.moveToTrash([image.id])
        model.goBack()

        #expect(model.destination != .scope(.kind(.image)))
    }
}

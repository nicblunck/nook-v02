import Foundation
import Testing
import NookLibrary
@testable import Nook

@MainActor
@Suite("Motion")
struct MotionTests {

    @Test("Imports announce the stable object identifiers that should plop in")
    func importArrival() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "arrival.txt"))
        let arrival = try #require(model.arrival)

        #expect(arrival.destination == .scope(.inbox))
        #expect(arrival.objectIDs == [object.id])
        #expect(arrival.objectOrder(object.id) == 0)
        #expect(model.reflowRevision > 0)
        #expect(model.sidebarReflowRevision > 0)
    }

    @Test("Creating organization announces the new sidebar and gallery entities")
    func organizationArrival() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        await model.createFolder(named: "Playground", in: nil)
        let folder = try #require(model.folderTree.first { $0.folder.name == "Playground" }?.folder)
        let folderArrival = try #require(model.arrival)
        #expect(folderArrival.folderIDs == [folder.id])

        await model.createCollection(named: "Ideas")
        let collection = try #require(model.collections.first { $0.name == "Ideas" })
        let collectionArrival = try #require(model.arrival)
        #expect(collectionArrival.collectionIDs == [collection.id])
        #expect(collectionArrival.revision > folderArrival.revision)
    }

    @Test("Navigation and ordinary refreshes do not invent arrivals")
    func refreshDoesNotAnnounceArrival() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .scope(.inbox))
        await model.refreshContents()
        model.navigate(to: .home)
        await model.refreshContents()

        #expect(model.arrival == nil)
        #expect(model.reflowRevision == 0)
        #expect(model.sidebarReflowRevision == 0)
    }

    @Test("Batch staggering is short and capped")
    func batchStaggerCap() {
        #expect(NookMotion.arrivalDelay(for: -1) == 0)
        #expect(abs(NookMotion.arrivalDelay(for: 5) - 0.225) < 0.000_001)
        #expect(abs(NookMotion.arrivalDelay(for: 20) - 0.36) < 0.000_001)
    }
}

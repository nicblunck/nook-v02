import Foundation
import SwiftUI
import Testing
import NookLibrary
@testable import Nook

@MainActor
@Suite("Motion")
struct MotionTests {

    @Test("Imports announce the stable object identifiers that should arrive")
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

    // MARK: The order of the windows
    //
    // Motion is the one part of the app that cannot be seen from a test, so
    // what is checked here is the thing that actually goes wrong when it is
    // got wrong: two windows overlapping, and something being drawn on top of
    // something else that is still moving.

    @Test("Nothing arrives until the layout has stopped moving")
    func arrivalWaitsForTheReflow() {
        #expect(NookMotion.arrivalDelay(for: 0) >= NookMotion.reflowWindow)
        // An index below zero is still an index into the same batch, so it
        // waits like the rest rather than landing on a moving grid.
        #expect(NookMotion.arrivalDelay(for: -1) == NookMotion.reflowWindow)
    }

    @Test("A departing item is gone before the layout has finished closing the gap")
    func departureLeadsTheReflow() {
        #expect(NookMotion.exitWindow < NookMotion.reflowWindow)
    }

    @Test("Batch staggering is short and capped")
    func batchStaggerCap() {
        let first = NookMotion.arrivalDelay(for: 0)
        #expect(NookMotion.arrivalDelay(for: 5) > first)
        // However large the import, the last item begins arriving on the same
        // tick as the cap — four hundred files settle in the window seven do.
        #expect(NookMotion.arrivalDelay(for: 20) == NookMotion.arrivalDelay(for: 400))
        #expect(NookMotion.arrivalDelay(for: 400) - first < 0.2)
    }

    @Test("Reduce Motion drops movement and keeps the fade")
    func reduceMotionDropsMovementOnly() {
        // A change of layout is movement, and movement is the thing being
        // reduced: the new arrangement is shown rather than travelled to.
        #expect(NookMotion.animation(.reflow, reduceMotion: true) == nil)
        // Everything else still fades. Something appearing with no transition
        // at all reads as a glitch rather than as an accommodation.
        #expect(NookMotion.animation(.presentation, reduceMotion: true) != nil)
        #expect(NookMotion.animation(.interaction, reduceMotion: true) != nil)
        #expect(NookMotion.animation(.enter, reduceMotion: true) != nil)
        #expect(NookMotion.animation(.exit, reduceMotion: true) != nil)
        #expect(NookMotion.animation(.navigation, reduceMotion: true) != nil)
    }

    @Test("Arriving somewhere is the quickest window in the system")
    func navigationIsTheShortestCut() {
        #expect(NookMotion.navigationWindow < NookMotion.exitWindow)
        #expect(NookMotion.navigationWindow < NookMotion.reflowWindow)
        #expect(NookMotion.navigationWindow < NookMotion.enterWindow)
    }
}

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

    @Test("A change is choreographed only through the stages it needs")
    func choreographyStages() {
        // Nothing leaves and nothing moves: an arrival has nothing to wait for.
        let appended = MotionChoreography(from: [1, 2], to: [1, 2, 3])
        #expect(appended == MotionChoreography(removes: false, shifts: false, inserts: true))
        #expect(appended.shiftDelay == 0)
        #expect(appended.enterDelay == 0)

        // Arriving ahead of survivors moves them along first.
        let prepended = MotionChoreography(from: [1, 2], to: [3, 1, 2])
        #expect(prepended.shifts)
        #expect(prepended.enterDelay == NookMotion.shiftDuration)

        // Leaving ahead of survivors: they wait for the exit before closing up.
        let removedFirst = MotionChoreography(from: [1, 2, 3], to: [2, 3])
        #expect(removedFirst == MotionChoreography(removes: true, shifts: true, inserts: false))
        #expect(removedFirst.shiftDelay == NookMotion.exitDuration)

        // Leaving from the end moves nobody.
        let removedLast = MotionChoreography(from: [1, 2, 3], to: [1, 2])
        #expect(removedLast == MotionChoreography(removes: true, shifts: false, inserts: false))

        // A replacement waits for the exit and the shift both.
        let replaced = MotionChoreography(from: [1, 2, 3], to: [1, 4, 3])
        #expect(replaced == MotionChoreography(removes: true, shifts: true, inserts: true))
        #expect(replaced.enterDelay == NookMotion.exitDuration + NookMotion.shiftDuration)

        // A reorder is a shift and nothing else.
        #expect(MotionChoreography(from: [1, 2, 3], to: [3, 2, 1]) == MotionChoreography(shifts: true))
        #expect(MotionChoreography(from: [1, 2], to: [1, 2]) == .none)

        // Nothing travels under Reduce Motion, so there is no shift to wait for.
        #expect(replaced.enterDelay(reduceMotion: true) == NookMotion.reducedDuration)
        #expect(prepended.enterDelay(reduceMotion: true) == 0)
    }

    @Test("The canvas learns where its contents came from, one query behind the destination")
    func contentsDestinationTrails() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        #expect(model.contentsDestination == nil)

        model.navigate(to: .scope(.inbox))
        #expect(model.contentsDestination == nil)
        await model.refreshContents()
        #expect(model.contentsDestination == .scope(.inbox))

        model.navigate(to: .home)
        #expect(model.contentsDestination == .scope(.inbox))
        await model.refreshContents()
        #expect(model.contentsDestination == .home)
    }

    @Test("Changes within a place are choreographed against what was showing")
    func contentsChangeFollowsTheChange() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))
        await model.refreshContents()

        let first = try #require(try await harness.importFile(named: "first.txt"))
        #expect(model.contentsChange.inserts)
        #expect(!model.contentsChange.removes)

        let second = try #require(try await harness.importFile(named: "second.txt"))
        _ = second
        #expect(model.contentsChange.inserts)

        await model.moveToTrash([first.id])
        #expect(model.contentsChange.removes)
        #expect(!model.contentsChange.inserts)
    }

    @Test("Batch staggering is short and capped")
    func batchStaggerCap() {
        #expect(NookMotion.arrivalDelay(for: -1) == 0)
        #expect(abs(NookMotion.arrivalDelay(for: 5) - 0.225) < 0.000_001)
        #expect(abs(NookMotion.arrivalDelay(for: 20) - 0.36) < 0.000_001)
    }
}

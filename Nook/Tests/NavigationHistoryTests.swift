import Foundation
import Testing
import NookLibrary
@testable import Nook

@MainActor
@Suite("Navigation history")
struct NavigationHistoryTests {

    @Test("Back retraces the path taken and Forward walks it again")
    func retracesThePath() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.destination == .home)
        #expect(!model.canGoBack)

        model.navigate(to: .scope(.inbox))
        model.navigate(to: .scope(.favorites))

        model.goBack()
        #expect(model.destination == .scope(.inbox))
        model.goBack()
        #expect(model.destination == .home)
        #expect(!model.canGoBack)

        model.goForward()
        #expect(model.destination == .scope(.inbox))
        model.goForward()
        #expect(model.destination == .scope(.favorites))
        #expect(!model.canGoForward)
    }

    /// Leaving Home for a scope changes both `isShowingHome` and `scope`. The
    /// user took one step, so Back has to undo one step.
    @Test("Leaving Home records one stop, not two")
    func leavingHomeIsOneStep() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .scope(.favorites))
        model.goBack()

        #expect(model.destination == .home)
        #expect(!model.canGoBack)
    }

    @Test("Opening a folder on the canvas is a step of its own")
    func canvasNavigationIsRecorded() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Papers", in: nil)
        let papers = try #require(model.folderTree.first?.folder)

        model.navigate(to: .scope(.inbox))
        // The canvas sets the scope directly rather than calling `navigate`.
        model.scope = .folder(papers.id)

        model.goBack()
        #expect(model.destination == .scope(.inbox))
    }

    @Test("A new step drops whatever was ahead")
    func newStepClearsForward() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .scope(.inbox))
        model.navigate(to: .scope(.favorites))
        model.goBack()
        #expect(model.canGoForward)

        model.navigate(to: .scope(.allObjects))
        #expect(!model.canGoForward)
    }

    /// Preview replaces the canvas rather than sitting beside it, so the first
    /// step back is out of preview and the place underneath is left alone.
    @Test("Back leaves preview before it leaves the place")
    func backLeavesPreviewFirst() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .scope(.inbox))
        let object = try #require(try await harness.importFile(named: "note.txt"))
        model.previewedObjectID = object.id

        #expect(model.canGoBack)
        model.goBack()
        #expect(model.previewedObjectID == nil)
        #expect(model.destination == .scope(.inbox))

        model.goBack()
        #expect(model.destination == .home)
    }

    @Test("Reopening the current destination leaves preview")
    func reopeningCurrentDestinationLeavesPreview() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        let object = try #require(try await harness.importFile(named: "note.txt"))
        model.previewedObjectID = object.id

        model.navigate(to: .home)

        #expect(model.previewedObjectID == nil)
        #expect(model.destination == .home)
        #expect(!model.canGoBack)
    }

    @Test("A deleted folder is taken out of the history")
    func deletedFoldersAreForgotten() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Scratch", in: nil)
        let scratch = try #require(model.folderTree.first?.folder)

        model.navigate(to: .scope(.folder(scratch.id)))
        model.navigate(to: .scope(.favorites))
        await model.deleteFolder(scratch.id)

        model.goBack()
        #expect(model.destination != .scope(.folder(scratch.id)))
        #expect(model.destination == .home)
    }

    @Test("Deleting a folder takes its subfolders out of the history too")
    func deletedSubfoldersAreForgotten() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Parent", in: nil)
        let parent = try #require(model.folderTree.first?.folder)
        await model.createFolder(named: "Child", in: parent.id)
        let child = try #require(model.folderTree.first?.children.first?.folder)

        model.navigate(to: .scope(.folder(child.id)))
        model.navigate(to: .scope(.favorites))
        await model.deleteFolder(parent.id)

        model.goBack()
        #expect(model.destination != .scope(.folder(child.id)))
    }
}

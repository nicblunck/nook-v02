import Foundation
import Testing
import NookLibrary
@testable import Nook

/// What a drop does is decided in one place, so these are tests of the
/// vocabulary rather than of any one surface: the sidebar, the canvas and a
/// folder card all hand their drops to the same list.
@MainActor
@Suite("Drag and Drop")
struct DragAndDropTests {

    @Test("A drag that starts on the selection carries all of it")
    func draggingSelectionCarriesIt() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let one = try #require(try await harness.importFile(named: "one.txt", contents: "one"))
        let two = try #require(try await harness.importFile(named: "two.txt", contents: "two"))
        model.selectAll()

        let carried = ObjectTransfer(id: one.id, carrying: Array(model.selectedObjectIDs))
        #expect(Set(carried.ids) == [one.id, two.id])
    }

    /// Dragging something that is not part of the selection acts on what was
    /// dragged, exactly as the context menu does.
    @Test("A drag that starts outside the selection carries only what was grabbed")
    func draggingOutsideSelectionCarriesOne() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let one = try #require(try await harness.importFile(named: "one.txt", contents: "one"))
        try await harness.importFile(named: "two.txt", contents: "two")

        let carried = ObjectTransfer(id: one.id, carrying: [])
        #expect(carried.ids == [one.id])
    }

    @Test("Dropping a selection on a folder moves all of it")
    func dropOnFolderMovesTheSelection() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let one = try #require(try await harness.importFile(named: "one.txt", contents: "one"))
        let two = try #require(try await harness.importFile(named: "two.txt", contents: "two"))
        await model.createFolder(named: "Work", in: nil)
        let folder = try #require(model.folderTree.first?.folder)

        await model.accept([.object(ObjectTransfer(id: one.id, carrying: [one.id, two.id]))],
                           at: .folder(folder.id))

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        #expect(Set(model.contents.objects.map(\.id)) == [one.id, two.id])
    }

    /// The point of the whole exercise: a drag that ends where it started is
    /// not a move, and nothing should be written for it.
    @Test("Dropping an object into the folder it already lives in changes nothing")
    func dropWhereItAlreadyIsDoesNothing() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "one.txt"))
        await model.createFolder(named: "Work", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        let before = try #require(model.contents.objects.first)

        await model.accept([.object(ObjectTransfer(id: before.id))], at: .currentLocation)

        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
        #expect(model.alert == nil)
    }

    @Test("Dropping on the canvas of a folder files things into that folder")
    func dropOnCanvasFilesIntoTheCurrentFolder() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "loose.txt"))
        await model.createFolder(named: "Work", in: nil)
        let folder = try #require(model.folderTree.first?.folder)

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        await model.accept([.object(ObjectTransfer(id: object.id))], at: .currentLocation)

        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    /// Recent and All Objects are queries over the library rather than places
    /// in it, so there is nowhere for a drop to land.
    @Test("A drop on a query lands nowhere")
    func dropOnAQueryDoesNothing() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "loose.txt"))
        await model.createFolder(named: "Work", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)

        model.navigate(to: .scope(.allObjects))
        await model.refreshContents()
        await model.accept([.object(ObjectTransfer(id: object.id))], at: .currentLocation)

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    @Test("Dropping on Inbox brings an object out of every folder")
    func dropOnInboxUnfilesIt() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "one.txt"))
        await model.createFolder(named: "Work", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)

        await model.accept([.object(ObjectTransfer(id: object.id))], at: .folder(nil))

        model.navigate(to: .scope(.inbox))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    @Test("Dropping on Favorites stars what was dropped")
    func dropOnFavoritesStarsIt() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "one.txt"))
        await model.accept([.object(ObjectTransfer(id: object.id))], at: .favorites)

        model.navigate(to: .scope(.favorites))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    @Test("Dropping on Recently Deleted throws it away")
    func dropOnTrashDeletesIt() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "one.txt"))
        await model.accept([.object(ObjectTransfer(id: object.id))], at: .trash)

        model.navigate(to: .scope(.recentlyDeleted))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    @Test("Dropping on a collection adds a membership and moves nothing")
    func dropOnCollectionAddsMembership() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "one.txt"))
        await model.createCollection(named: "Reading")
        let collection = try #require(model.collections.first)

        await model.accept([.object(ObjectTransfer(id: object.id))], at: .collection(collection.id))

        model.navigate(to: .scope(.collection(collection.id)))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])

        model.navigate(to: .scope(.inbox))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    @Test("Dropping on a tag applies it")
    func dropOnTagAppliesIt() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let first = try #require(try await harness.importFile(named: "one.txt", contents: "one"))
        await model.addTag("Blue", to: [first.id])
        let tag = try #require(model.tags.first)

        let second = try #require(try await harness.importFile(named: "two.txt", contents: "two"))
        await model.accept([.object(ObjectTransfer(id: second.id))], at: .tag(tag.id))

        model.navigate(to: .scope(.tag(tag.id)))
        await model.refreshContents()
        #expect(Set(model.contents.objects.map(\.id)) == [first.id, second.id])
    }

    @Test("A folder dropped on a folder becomes its child")
    func folderDropReparents() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Work", in: nil)
        await model.createFolder(named: "Archive", in: nil)
        let work = try #require(model.folderTree.first { $0.folder.name == "Work" }?.folder)
        let archive = try #require(model.folderTree.first { $0.folder.name == "Archive" }?.folder)

        await model.accept([.folder(FolderTransfer(id: archive.id))], at: .folder(work.id))

        let reparented = try #require(model.allFolders.first { $0.folder.id == archive.id }?.folder)
        #expect(reparented.parentID == work.id)
    }

    /// The store refuses this too. Refusing it here is what keeps the sidebar
    /// from offering a drop whose only outcome is an alert.
    @Test("A folder cannot be dropped inside its own subtree")
    func folderCannotSwallowItself() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)
        await model.createFolder(named: "Notes", in: work.id)
        let notes = try #require(model.allFolders.first { $0.folder.name == "Notes" }?.folder)

        await model.accept([.folder(FolderTransfer(id: work.id))], at: .folder(notes.id))

        let unmoved = try #require(model.allFolders.first { $0.folder.id == work.id }?.folder)
        #expect(unmoved.parentID == nil)
        #expect(model.alert == nil)
    }

    @Test("Files dropped on a folder are imported into it")
    func filesDropIntoTheFolderTheyLandOn() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        await model.createFolder(named: "Work", in: nil)
        let folder = try #require(model.folderTree.first?.folder)

        let url = harness.scratch.appending(path: "dropped.txt")
        try Data("dropped".utf8).write(to: url)
        await model.accept([.file(url)], at: .folder(folder.id))

        model.navigate(to: .scope(.folder(folder.id)))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.originalFilename) == ["dropped.txt"])
    }

    @Test("Files dropped on a collection are imported and gathered")
    func filesDropIntoACollection() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        await model.createCollection(named: "Reading")
        let collection = try #require(model.collections.first)

        let url = harness.scratch.appending(path: "dropped.txt")
        try Data("dropped".utf8).write(to: url)
        await model.accept([.file(url)], at: .collection(collection.id))

        model.navigate(to: .scope(.collection(collection.id)))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.originalFilename) == ["dropped.txt"])
    }
}

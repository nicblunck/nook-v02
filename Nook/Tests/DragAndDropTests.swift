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

    @Test("Dropping on the Trash throws it away")
    func dropOnTrashDeletesIt() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "one.txt"))
        await model.accept([.object(ObjectTransfer(id: object.id))], at: .trash)

        model.navigate(to: .scope(.trash))
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

    @Test("A folder dropped on the sidebar root becomes a root folder")
    func folderDropMovesToRoot() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)
        await model.createFolder(named: "Archive", in: work.id)
        let archive = try #require(model.allFolders.first { $0.folder.name == "Archive" }?.folder)

        await model.accept([.folder(FolderTransfer(id: archive.id))], at: .folder(nil))

        let moved = try #require(model.folderTree.first { $0.folder.id == archive.id }?.folder)
        #expect(moved.parentID == nil)
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

    @Test("Dropping an object on the Hidden icon hides it and detaches it from its folder")
    func objectDropOnHiddenIconMovesItToHiddenRoot() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "kept.txt"))
        await model.createFolder(named: "Work", in: nil)
        let folder = try #require(model.folderTree.first?.folder)
        await model.move([object.id], to: folder.id)

        await model.accept([.object(ObjectTransfer(id: object.id))], at: .hidden)

        await model.openHidden()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    /// A folder reached only by having descended into Hidden is never in the
    /// ordinary tree, which is exactly the folder this drop exists to
    /// promote — so it must not be looked up in that tree to be found.
    @Test("Dropping a nested folder on the Hidden icon promotes it to Hidden's top level")
    func nestedFolderDropOnHiddenIconPromotesIt() async throws {
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
        model.navigate(to: .scope(.folder(parent.id)))
        await model.loadPreferences()
        await model.refreshContents()
        #expect(model.contents.folders.map(\.id) == [child.id])

        await model.accept([.folder(FolderTransfer(id: child.id))], at: .hidden)

        model.navigate(to: .scope(.hidden))
        await model.loadPreferences()
        await model.refreshContents()
        #expect(Set(model.contents.folders.map(\.id)) == [parent.id, child.id])

        model.navigate(to: .scope(.folder(parent.id)))
        await model.loadPreferences()
        await model.refreshContents()
        #expect(model.contents.folders.isEmpty)
    }

    // MARK: The sidebar's answer while a drag is overhead

    /// The sidebar lights a row only when letting go there would do
    /// something, and the rules that decide that are the rules the drop is
    /// then made by — so what lights up is what happens.
    @Test("A folder is offered every folder but its own subtree")
    func folderIsOfferedEverywhereButInsideItself() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Work", in: nil)
        await model.createFolder(named: "Archive", in: nil)
        let work = try #require(model.folderTree.first { $0.folder.name == "Work" }?.folder)
        let archive = try #require(model.folderTree.first { $0.folder.name == "Archive" }?.folder)
        await model.createFolder(named: "Notes", in: work.id)
        let notes = try #require(model.allFolders.first { $0.folder.name == "Notes" }?.folder)

        let dragging = SidebarDropRules.Payload.folder(work.id)
        #expect(SidebarDropRules.verdict(for: dragging, on: .folder(archive.id), model: model) == .move)
        #expect(SidebarDropRules.verdict(for: dragging, on: .folder(nil), model: model) == .move)
        #expect(SidebarDropRules.verdict(for: dragging, on: .folder(work.id), model: model) == .forbidden)
        #expect(SidebarDropRules.verdict(for: dragging, on: .folder(notes.id), model: model) == .forbidden)
    }

    @Test("A folder is not offered anywhere that gathers objects")
    func folderIsNotOfferedToGatheringPlaces() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)
        await model.createCollection(named: "Reading")
        let collection = try #require(model.collections.first)

        let dragging = SidebarDropRules.Payload.folder(work.id)
        #expect(SidebarDropRules.verdict(for: dragging, on: .collection(collection.id), model: model) == .nothing)
        #expect(SidebarDropRules.verdict(for: dragging, on: .favorites, model: model) == .nothing)
        #expect(SidebarDropRules.verdict(for: dragging, on: .hidden, model: model) == .move)
    }

    /// The drag begins on the folder's own row, and which folder it is takes
    /// a moment to learn. Until then no folder is lit — least of all that one.
    @Test("A folder drag is offered nothing until it is known which folder")
    func unidentifiedFolderIsOfferedNothing() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)

        let pending = SidebarDropRules.Payload.folder(nil)
        #expect(SidebarDropRules.verdict(for: pending, on: .folder(work.id), model: model) == .nothing)
        #expect(SidebarDropRules.verdict(for: pending, on: .folder(nil), model: model) == .nothing)
    }

    @Test("Objects move into places and are added to what gathers them")
    func objectsAreOfferedEveryPlace() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)
        await model.createCollection(named: "Reading")
        let collection = try #require(model.collections.first)

        #expect(SidebarDropRules.verdict(for: .objects, on: .folder(work.id), model: model) == .move)
        #expect(SidebarDropRules.verdict(for: .objects, on: .folder(nil), model: model) == .move)
        #expect(SidebarDropRules.verdict(for: .objects, on: .collection(collection.id), model: model) == .add)
        #expect(SidebarDropRules.verdict(for: .objects, on: .favorites, model: model) == .add)
        #expect(SidebarDropRules.verdict(for: .files, on: .folder(work.id), model: model) == .add)
        #expect(SidebarDropRules.verdict(for: .files, on: .collection(collection.id), model: model) == .add)
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

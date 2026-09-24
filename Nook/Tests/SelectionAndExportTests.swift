import Foundation
import Testing
import NookLibrary
@testable import Nook

@MainActor
@Suite("Selection")
struct SelectionTests {

    @Test("Select All takes the objects on the canvas, and Deselect gives them back")
    func selectsAndDeselects() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        try await harness.importFile(named: "one.txt", contents: "one")
        try await harness.importFile(named: "two.txt", contents: "two")
        #expect(model.contents.objects.count == 2)

        model.selectAll()
        #expect(model.selection.count == 2)

        model.deselectAll()
        #expect(model.selection.isEmpty)
    }

    /// A menu command outranks the field editor in SwiftUI, so Select All has
    /// to stand down rather than take the canvas out from under someone who is
    /// selecting the text they just typed.
    @Test("Select All stands down while a text field has the keyboard")
    func standsDownWhileTyping() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        try await harness.importFile(named: "one.txt")
        #expect(model.canSelectAll)

        model.isTextEntryFocused = true
        #expect(!model.canSelectAll)

        model.isTextEntryFocused = false
        #expect(model.canSelectAll)
    }

    /// Favorite is bound to a bare period, the way Photos binds it. That makes
    /// it a character before it is a shortcut, so the rename prompt has to take
    /// it back — an alert's field is still a field.
    @Test("A naming prompt takes the keyboard back from the canvas")
    func namingPromptHoldsTheKeyboard() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        try await harness.importFile(named: "one.txt")
        #expect(!model.isTypingText)
        #expect(model.canSelectAll)

        model.namingPrompt = .renameFolder(FolderID())
        #expect(model.isTypingText)
        #expect(!model.canSelectAll)

        model.namingPrompt = nil
        #expect(!model.isTypingText)
        #expect(model.canSelectAll)
    }

    @Test("There is nothing to select in an empty place")
    func nothingToSelectWhenEmpty() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        #expect(!harness.model.canSelectAll)
        #expect(!harness.model.canBeginSelecting)
    }
}

/// iOS picks several things through Select rather than a modifier key: a tap
/// ticks an item instead of opening it, until Done.
@MainActor
@Suite("Select mode")
struct SelectModeTests {

    @Test("Select starts with nothing picked, and a tap picks and puts back")
    func startsEmptyAndToggles() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let one = try #require(try await harness.importFile(named: "one.txt", contents: "one"))
        let two = try #require(try await harness.importFile(named: "two.txt", contents: "two"))
        #expect(model.canBeginSelecting)

        // What was last opened stays selected on iOS; Select must not
        // start with it already ticked.
        model.selection = [one.id]
        model.beginSelecting()
        #expect(model.isSelecting)
        #expect(model.selection.isEmpty)

        model.toggleSelection(one.id)
        model.toggleSelection(two.id)
        #expect(model.selection == [one.id, two.id])
        #expect(model.isEverythingSelected)

        model.toggleSelection(one.id)
        #expect(model.selection == [two.id])
        #expect(!model.isEverythingSelected)

        model.endSelecting()
        #expect(!model.isSelecting)
        #expect(model.selection.isEmpty)
    }

    @Test("Leaving for another place leaves Select")
    func leavingThePlaceEndsSelecting() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let one = try #require(try await harness.importFile(named: "one.txt"))
        model.beginSelecting()
        model.toggleSelection(one.id)

        model.navigate(to: .scope(.favorites))
        await model.refreshContents()
        #expect(!model.isSelecting)
        #expect(model.selection.isEmpty)
    }

    @Test("A tap while selecting picks a folder instead of going in")
    func picksFolders() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        await model.createFolder(named: "Papers", in: nil)
        let papers = try #require(model.folderTree.first?.folder)
        model.navigate(to: .scope(.folder(papers.id)))
        await model.refreshContents()
        await model.createFolder(named: "Drafts", in: papers.id)
        await model.refreshContents()
        let drafts = try #require(model.contents.folders.first)

        // A place holding only folders still has something to select.
        #expect(model.canBeginSelecting)
        model.beginSelecting()
        model.toggleSelection(.folder(drafts.id))
        #expect(model.folderSelection == [drafts.id])
        #expect(model.selectedItemCount == 1)
        #expect(model.isEverythingSelected)
    }

    @Test("Opening something leaves Select")
    func openingEndsSelecting() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let one = try #require(try await harness.importFile(named: "one.txt"))
        model.beginSelecting()
        model.openObject(one)
        #expect(!model.isSelecting)
        #expect(model.previewedObjectID == one.id)
    }
}

@MainActor
@Suite("Export")
struct ExportTests {

    @Test("An exported original comes back byte-for-byte under its own name")
    func exportsTheOriginal() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "notes.txt", contents: "kept"))
        let destination = try harness.makeDirectory(named: "Exported")

        model.beginExport(of: [object])
        #expect(model.isExportPickerPresented)
        await model.completeExport(to: destination)

        let written = destination.appending(path: "notes.txt")
        #expect(FileManager.default.fileExists(atPath: written.path(percentEncoded: false)))
        #expect(try String(contentsOf: written, encoding: .utf8) == "kept")
        #expect(model.alert == nil)
        #expect(model.toast?.message == LocalizedStringResource("Exported one item"))
        #expect(model.toast?.systemImage == "square.and.arrow.up.fill")
        #expect(model.toast?.tint == .blue)
    }

    /// Objects share stored files and can repeat an original filename, so an
    /// export names its way around a collision rather than overwriting what is
    /// already in the folder.
    @Test("A second export of the same name lands beside the first")
    func namesAroundCollisions() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "report.txt", contents: "once"))
        let destination = try harness.makeDirectory(named: "Exported")

        model.beginExport(of: [object])
        await model.completeExport(to: destination)
        model.beginExport(of: [object])
        await model.completeExport(to: destination)

        let names = try FileManager.default
            .contentsOfDirectory(atPath: destination.path(percentEncoded: false))
            .sorted()
        #expect(names == ["report 2.txt", "report.txt"])
        #expect(model.alert == nil)
    }

    @Test("An object with no original on this device is not offered a picker")
    func refusesWhenThereIsNothingToExport() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        // A link is an object in its own right and has no stored bytes.
        await model.importItems([.link(URL(string: "https://example.com/page")!)])
        let link = try #require(model.contents.objects.first { $0.kind == .link })

        model.beginExport(of: [link])
        #expect(!model.isExportPickerPresented)
        #expect(model.alert != nil)
    }
}

@MainActor
@Suite("Action confirmations")
struct ActionConfirmationTests {

    @Test("Imports and mutations publish success toasts")
    func publishesSuccessToasts() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        let object = try #require(try await harness.importFile(named: "toast.txt"))
        #expect(model.toast?.message == LocalizedStringResource("Added one item to Nook"))
        #expect(model.toast?.tint == .green)

        await model.setFavorite(true, for: [object.id])
        #expect(model.toast?.message == LocalizedStringResource("Added to Favorites"))
        #expect(model.toast?.systemImage == "star.fill")
        #expect(model.toast?.tint == .yellow)

        await model.moveToTrash([object.id])
        #expect(model.toast?.message == LocalizedStringResource("Moved to Trash"))
        #expect(model.toast?.systemImage == "trash.fill")
        #expect(model.toast?.tint == .red)
    }
}

@MainActor
@Suite("Trash")
struct TrashTests {

    @Test("Delete asks before moving the selection to the Trash, naming what it is")
    func deleteKeyAsksFirst() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))
        let object = try #require(try await harness.importFile(named: "Receipt.txt"))
        model.selection = [object.id]

        #expect(model.requestTrashForKeyboard())
        let request = try #require(model.trashRequest)
        #expect(request.title == "Move “\(object.title)” to Trash?")
        #expect(request.message == nil)
        #expect(request.confirmTitle == "Move to Trash")
        // Nothing has gone anywhere until the answer is yes.
        #expect(model.contents.objects.map(\.id) == [object.id])

        await model.confirm(request)
        #expect(model.trashRequest == nil)
        #expect(model.contents.objects.isEmpty)
        #expect(model.counts[.trash] == 1)
    }

    @Test("Delete on something already in the Trash asks to delete it for good")
    func deleteKeyInTheTrashDeletesImmediately() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))
        let object = try #require(try await harness.importFile(named: "old.txt"))
        await model.moveToTrash([object.id])

        model.navigate(to: .scope(.trash))
        await model.refreshContents()
        model.selection = [object.id]
        #expect(model.requestTrashForKeyboard())
        let request = try #require(model.trashRequest)
        #expect(request.title == "Delete “\(object.title)” Immediately?")
        #expect(request.message == "Deleted items cannot be recovered.")

        await model.confirm(request)
        #expect(model.contents.isEmpty)
        #expect(model.counts[.trash] == 0)
    }

    @Test("Delete with nothing chosen asks nothing")
    func deleteKeyWithNothingChosen() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))
        _ = try #require(try await harness.importFile(named: "loose.txt"))
        model.deselectAll()

        #expect(!model.requestTrashForKeyboard())
        #expect(model.trashRequest == nil)
    }

    @Test("A folder in the Trash is put back whole")
    func folderPutBack() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        await model.createFolder(named: "Taxes", in: nil)
        let taxes = try #require(model.folderTree.first?.folder)

        model.requestMoveToTrash(taxes)
        #expect(model.trashRequest?.title == "Move “Taxes” to Trash?")
        await model.confirm(try #require(model.trashRequest))
        #expect(model.folderTree.isEmpty)

        model.navigate(to: .scope(.trash))
        await model.refreshContents()
        #expect(model.contents.folders.map(\.name) == ["Taxes"])
        #expect(model.contents.folders.first?.isInTrash == true)

        await model.restoreFolder(taxes.id)
        #expect(model.folderTree.map(\.folder.name) == ["Taxes"])
        #expect(model.contents.isEmpty)
    }

    @Test("Empty Trash asks, warns, and is only offered with something to empty")
    func emptyTrash() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))

        model.requestEmptyTrash()
        #expect(model.trashRequest == nil)

        let object = try #require(try await harness.importFile(named: "gone.txt"))
        await model.moveToTrash([object.id])
        #expect(model.canEmptyTrash)

        model.requestEmptyTrash()
        let request = try #require(model.trashRequest)
        #expect(request.title == "Empty Trash?")
        #expect(request.message == "Deleted items cannot be recovered.")
        #expect(request.confirmTitle == "Empty Trash")

        await model.confirm(request)
        #expect(!model.canEmptyTrash)
    }
}

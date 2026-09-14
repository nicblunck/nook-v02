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

        await model.setFavorite(true, for: [object.id])
        #expect(model.toast?.message == LocalizedStringResource("Added to Favorites"))
        #expect(model.toast?.systemImage == "star.fill")

        await model.delete([object.id])
        #expect(model.toast?.message == LocalizedStringResource("Moved to Recently Deleted"))
        #expect(model.toast?.systemImage == "trash.fill")
    }
}

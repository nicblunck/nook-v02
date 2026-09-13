#if os(macOS)
import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
import NookLibrary
@testable import Nook

/// The Mac sidebar, hosted in a window that is never shown, driven through
/// the outline's own delegate methods — the same calls AppKit makes for a
/// click, an arrow key or a drag.
@MainActor
@Suite("Mac sidebar")
struct MacSidebarTests {

    @Test("The outline names the library's places")
    func outlineNamesThePlaces() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)
        await model.createFolder(named: "Notes", in: work.id)
        await model.createCollection(named: "Reading")

        let sidebar = try await HostedSidebar(model: model)
        #expect(sidebar.titles(under: .section(.library)) == ["Home", "Inbox", "Recent", "Favorites", "All Objects"])
        #expect(sidebar.titles(under: .section(.folders)) == ["Work"])
        #expect(sidebar.titles(under: .destination(.scope(.folder(work.id)))) == ["Notes"])
        #expect(sidebar.titles(under: .section(.collections)) == ["Reading"])
        #expect(sidebar.titles(under: .section(.mediaTypes)) == ObjectKind.mediaTypes.map(\.pluralDisplayName))
        // No tags, no Tags section.
        #expect(sidebar.item(.section(.tags)) == nil)
    }

    @Test("Selecting a row navigates, and navigating selects the row")
    func selectionAndNavigationAgree() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        let sidebar = try await HostedSidebar(model: model)

        // The app opens on Home, and the outline says so.
        #expect(sidebar.selectedDestination == .home)

        sidebar.click(.destination(.scope(.inbox)))
        #expect(model.destination == .scope(.inbox))

        model.navigate(to: .scope(.favorites))
        await sidebar.settle()
        #expect(sidebar.selectedDestination == .scope(.favorites))
    }

    @Test("Folder expansion follows the model both ways")
    func expansionFollowsTheModel() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)
        await model.createFolder(named: "Notes", in: work.id)

        let sidebar = try await HostedSidebar(model: model)
        let workItem = try #require(sidebar.item(.destination(.scope(.folder(work.id)))))
        #expect(!sidebar.outline.isItemExpanded(workItem))

        model.expandedFolders.insert(work.id)
        await sidebar.settle()
        #expect(sidebar.outline.isItemExpanded(workItem))

        sidebar.outline.collapseItem(workItem)
        #expect(!model.expandedFolders.contains(work.id))
    }

    @Test("Rows come and go with the library, without losing their places")
    func rowsFollowTheLibrary() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        await model.createFolder(named: "Work", in: nil)
        let sidebar = try await HostedSidebar(model: model)
        let work = try #require(model.folderTree.first?.folder)
        let workBefore = try #require(sidebar.item(.destination(.scope(.folder(work.id)))))

        await model.createFolder(named: "Archive", in: nil)
        await model.createCollection(named: "Reading")
        await sidebar.settle()
        #expect(sidebar.titles(under: .section(.folders)) == ["Archive", "Work"])
        #expect(sidebar.titles(under: .section(.collections)) == ["Reading"])
        // The same object still stands for Work: that is what keeps its
        // expansion and selection through the change.
        #expect(sidebar.item(workBefore.id) === workBefore)

        let archive = try #require(model.folderTree.first { $0.folder.name == "Archive" }?.folder)
        await model.deleteFolder(archive.id)
        await sidebar.settle()
        #expect(sidebar.titles(under: .section(.folders)) == ["Work"])
    }

    @Test("A folder is offered every folder but its own subtree, and lands where it is dropped")
    func folderDrop() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        await model.createFolder(named: "Work", in: nil)
        await model.createFolder(named: "Archive", in: nil)
        let work = try #require(model.folderTree.first { $0.folder.name == "Work" }?.folder)
        let archive = try #require(model.folderTree.first { $0.folder.name == "Archive" }?.folder)
        await model.createFolder(named: "Notes", in: work.id)
        let notes = try #require(model.allFolders.first { $0.folder.name == "Notes" }?.folder)
        await model.createCollection(named: "Reading")
        let collection = try #require(model.collections.first)

        let sidebar = try await HostedSidebar(model: model)
        let drag = DragStandIn(folder: work.id)

        #expect(sidebar.validate(drag, on: .destination(.scope(.folder(archive.id)))) == .move)
        #expect(sidebar.validate(drag, on: .section(.folders)) == .move)
        #expect(sidebar.validate(drag, on: .destination(.scope(.inbox))) == .move)
        #expect(sidebar.validate(drag, on: .destination(.scope(.folder(work.id)))) == [])
        #expect(sidebar.validate(drag, on: .destination(.scope(.folder(notes.id)))) == [])
        #expect(sidebar.validate(drag, on: .destination(.scope(.collection(collection.id)))) == [])
        #expect(sidebar.validate(drag, on: .destination(.scope(.favorites))) == [])
        // Between two rows counts as on their parent.
        #expect(sidebar.validate(drag, on: .destination(.scope(.folder(archive.id))), between: 0) == .move)

        #expect(sidebar.accept(drag, on: .destination(.scope(.folder(archive.id)))))
        await sidebar.settle()
        let moved = try #require(model.allFolders.first { $0.folder.id == work.id }?.folder)
        #expect(moved.parentID == archive.id)
    }

    @Test("Objects move into places and are added to what gathers them")
    func objectDrop() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))
        let object = try #require(try await harness.importFile(named: "one.txt"))
        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)

        let sidebar = try await HostedSidebar(model: model)
        let drag = DragStandIn(objects: [object.id])

        #expect(sidebar.validate(drag, on: .destination(.scope(.folder(work.id)))) == .move)
        #expect(sidebar.validate(drag, on: .destination(.scope(.favorites))) == .copy)
        #expect(sidebar.validate(drag, on: .destination(.scope(.recent))) == [])
        #expect(sidebar.validate(drag, on: .destination(.scope(.allObjects))) == [])
        #expect(sidebar.validate(drag, on: .destination(.scope(.kind(.image)))) == [])

        #expect(sidebar.accept(drag, on: .destination(.scope(.folder(work.id)))))
        await sidebar.settle()
        model.navigate(to: .scope(.folder(work.id)))
        await model.refreshContents()
        #expect(model.contents.objects.map(\.id) == [object.id])
    }

    @Test("A dragged folder row writes what the canvas can read")
    func folderRowWritesItsIdentity() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)

        let sidebar = try await HostedSidebar(model: model)
        let item = try #require(sidebar.item(.destination(.scope(.folder(work.id)))))
        let writer = try #require(sidebar.coordinator.outlineView(sidebar.outline, pasteboardWriterForItem: item))
        let pasteboard = NSPasteboard(name: .init("nook.tests.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.writeObjects([writer])
        #expect(SidebarDropRules.payload(on: pasteboard) == .folder(work.id))
        // Nothing but a folder is draggable.
        let inbox = try #require(sidebar.item(.destination(.scope(.inbox))))
        #expect(sidebar.coordinator.outlineView(sidebar.outline, pasteboardWriterForItem: inbox) == nil)
    }

    @Test("The keys the sidebar means something by reach the model")
    func keysReachTheModel() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)
        await model.createFolder(named: "Notes", in: work.id)
        model.navigate(to: .scope(.folder(work.id)))

        let sidebar = try await HostedSidebar(model: model)
        #expect(sidebar.press(MacKey.right))
        #expect(model.expandedFolders.contains(work.id))
        #expect(sidebar.press(MacKey.left))
        #expect(!model.expandedFolders.contains(work.id))
        #expect(sidebar.press(MacKey.tab))
        #expect(model.keyboardPane == .canvas)
        // Up and down are the outline's own.
        #expect(!sidebar.press(125))
    }

    @Test("A folder's menu offers what its context menu did")
    func folderMenu() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        await model.createFolder(named: "Work", in: nil)
        let work = try #require(model.folderTree.first?.folder)

        let sidebar = try await HostedSidebar(model: model)
        let menu = try #require(sidebar.menu(for: .destination(.scope(.folder(work.id)))))
        #expect(menu.items.map(\.title).filter { !$0.isEmpty }
                == ["Rename…", "New Subfolder…", "Customize…", "Hide", "Lock", "Delete Folder"])
        #expect(sidebar.menu(for: .destination(.scope(.inbox))) == nil)
    }
}

// MARK: - Hosting

/// The sidebar in a window that is never ordered front.
@MainActor
private final class HostedSidebar {
    let window: NSWindow
    let outline: SidebarOutlineView
    let coordinator: MacSidebar.Coordinator

    init(model: LibraryModel) async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SidebarView(model: model))
        window.contentView?.layoutSubtreeIfNeeded()
        // Sleeping hands the main run loop back, which is where SwiftUI
        // builds the outline.
        try? await Task.sleep(for: .milliseconds(100))
        let content = try #require(window.contentView)
        outline = try #require(Self.find(SidebarOutlineView.self, in: content))
        coordinator = try #require(outline.dataSource as? MacSidebar.Coordinator)
    }

    /// Lets SwiftUI carry a model change through to the outline: sleeping
    /// here hands the main run loop back, which is where the update runs.
    func settle() async {
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    func item(_ id: SidebarItem.ID) -> SidebarItem? {
        func search(_ parent: Any?) -> SidebarItem? {
            for index in 0..<coordinator.outlineView(outline, numberOfChildrenOfItem: parent) {
                guard let item = coordinator.outlineView(outline, child: index, ofItem: parent) as? SidebarItem else { continue }
                if item.id == id { return item }
                if let found = search(item) { return found }
            }
            return nil
        }
        return search(nil)
    }

    func titles(under id: SidebarItem.ID) -> [String] {
        item(id)?.children.map(\.row.title) ?? []
    }

    var selectedDestination: LibraryDestination? {
        (outline.item(atRow: outline.selectedRow) as? SidebarItem)?.row.destination
    }

    func click(_ id: SidebarItem.ID) {
        guard let item = item(id) else { return }
        outline.selectRowIndexes([outline.row(forItem: item)], byExtendingSelection: false)
    }

    func validate(_ drag: DragStandIn, on id: SidebarItem.ID, between childIndex: Int = NSOutlineViewDropOnItemIndex) -> NSDragOperation {
        coordinator.outlineView(outline, validateDrop: drag, proposedItem: item(id), proposedChildIndex: childIndex)
    }

    func accept(_ drag: DragStandIn, on id: SidebarItem.ID) -> Bool {
        coordinator.outlineView(outline, acceptDrop: drag, item: item(id), childIndex: NSOutlineViewDropOnItemIndex)
    }

    func press(_ keyCode: UInt16) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: keyCode)!
        return coordinator.handle(event)
    }

    func menu(for id: SidebarItem.ID) -> NSMenu? {
        guard let item = item(id) else { return nil }
        return outline.menuProvider?(outline.row(forItem: item))
    }
}

// MARK: - A drag

/// What AppKit hands a drop destination, carrying a real pasteboard.
private final class DragStandIn: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard

    init(folder: FolderID) {
        pasteboard = NSPasteboard(name: .init("nook.tests.drag.\(UUID())"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(try! JSONEncoder().encode(FolderTransfer(id: folder)), forType: .init(UTType.nookFolder.identifier))
        pasteboard.writeObjects([item])
    }

    init(objects: [ObjectID]) {
        pasteboard = NSPasteboard(name: .init("nook.tests.drag.\(UUID())"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(try! JSONEncoder().encode(ObjectTransfer(ids: objects)), forType: .init(UTType.nookObject.identifier))
        pasteboard.writeObjects([item])
    }

    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],
                                for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
#endif

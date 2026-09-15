import CoreGraphics
import Foundation
import Testing
import NookLibrary
@testable import Nook

/// The geometry, tested without a window.
///
/// What "up" means depends on where the layout actually put things, so the
/// interesting cases are the ones no index arithmetic gets right: a masonry
/// column whose neighbour in sort order is nowhere near it, and a row that has
/// not been measured yet.
@Suite("Canvas navigation")
struct CanvasNavigationTests {

    /// Three columns, three rows, the last one short — the ordinary grid.
    private struct Grid {
        let ids = (0..<8).map { _ in CanvasItemID.object(ObjectID()) }
        var frames: [CanvasItemID: CGRect] = [:]

        init() {
            for (index, id) in ids.enumerated() {
                frames[id] = CGRect(x: CGFloat(index % 3) * 100,
                                    y: CGFloat(index / 3) * 100,
                                    width: 90, height: 90)
            }
        }

        func destination(from origin: CanvasItemID?, _ direction: CanvasDirection) -> CanvasItemID? {
            CanvasNavigation.destination(from: origin, direction: direction,
                                         order: ids, frames: frames)
        }
    }

    @Test("Left and right move to the adjacent object in the rendered row")
    func stepsThroughRenderedRow() {
        let grid = Grid()
        #expect(grid.destination(from: grid.ids[0], .right) == grid.ids[1])
        #expect(grid.destination(from: grid.ids[1], .left) == grid.ids[0])
    }

    /// A horizontal arrow does not turn into vertical movement just because
    /// the next item in the backing order starts another row.
    @Test("Left and right stop at the rendered row edges")
    func stopsAtRowEdges() {
        let grid = Grid()
        #expect(grid.destination(from: grid.ids[2], .right) == nil)
        #expect(grid.destination(from: grid.ids[3], .left) == nil)
        #expect(grid.destination(from: grid.ids[5], .right) == nil)
        #expect(grid.destination(from: grid.ids[6], .left) == nil)
    }

    @Test("There is nothing before the first item or after the last")
    func stopsAtTheEnds() {
        let grid = Grid()
        #expect(grid.destination(from: grid.ids[0], .left) == nil)
        #expect(grid.destination(from: grid.ids[7], .right) == nil)
    }

    @Test("Up and down move a whole row, keeping the column")
    func movesByRow() {
        let grid = Grid()
        #expect(grid.destination(from: grid.ids[1], .down) == grid.ids[4])
        #expect(grid.destination(from: grid.ids[4], .up) == grid.ids[1])
        #expect(grid.destination(from: grid.ids[4], .down) == grid.ids[7])
    }

    /// At the edge there is no row to reach and the key does nothing, which is
    /// what every other Mac list does. Sliding to the last or first item
    /// instead would be movement the key did not ask for.
    @Test("Up on the first row and down on the last do nothing")
    func stopsAtTheEdges() {
        let grid = Grid()
        #expect(grid.destination(from: grid.ids[6], .down) == nil)
        #expect(grid.destination(from: grid.ids[7], .down) == nil)
        #expect(grid.destination(from: grid.ids[1], .up) == nil)
        #expect(grid.destination(from: grid.ids[0], .up) == nil)
    }

    /// A partial last row is reached by whichever item is nearest, rather than
    /// by the column the cursor happened to be in — the column may not be
    /// there any more.
    @Test("Down into a short last row lands on the nearest item in it")
    func reachesAPartialRow() {
        let grid = Grid()
        // The third column has no item on the last row; the second does.
        #expect(grid.destination(from: grid.ids[5], .down) == grid.ids[7])
        #expect(grid.destination(from: grid.ids[7], .up) == grid.ids[4])
    }

    @Test("A short final row keeps horizontal movement inside that row")
    func movesWithinAPartialRow() {
        let grid = Grid()
        #expect(grid.destination(from: grid.ids[6], .right) == grid.ids[7])
        #expect(grid.destination(from: grid.ids[7], .left) == grid.ids[6])
        #expect(grid.destination(from: grid.ids[7], .right) == nil)
    }

    @Test("The first key press enters the canvas from the edge it points away from")
    func entersFromTheEdge() {
        let grid = Grid()
        #expect(grid.destination(from: nil, .down) == grid.ids.first)
        #expect(grid.destination(from: nil, .right) == grid.ids.first)
        #expect(grid.destination(from: nil, .up) == grid.ids.last)
        #expect(grid.destination(from: nil, .left) == grid.ids.last)
    }

    /// Masonry drops each item into whichever column is shortest, so the item
    /// after another in sort order is routinely in the other column. Down has
    /// to follow the column on screen, not the sequence.
    @Test("Down follows the column the cursor is in, not the sort order")
    func followsMasonryColumns() {
        let a = CanvasItemID.object(ObjectID())
        let b = CanvasItemID.object(ObjectID())
        let c = CanvasItemID.object(ObjectID())
        let d = CanvasItemID.object(ObjectID())
        // Two columns: a and c on the left, b and d on the right, with the
        // ragged tops masonry produces.
        let frames: [CanvasItemID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 90, height: 120),
            b: CGRect(x: 200, y: 0, width: 90, height: 60),
            c: CGRect(x: 0, y: 134, width: 90, height: 80),
            d: CGRect(x: 200, y: 74, width: 90, height: 140)
        ]
        let order = [a, b, c, d]

        // `d` starts higher than `c`, so a purely vertical answer would drift
        // across to the other column.
        #expect(CanvasNavigation.destination(from: a, direction: .down,
                                             order: order, frames: frames) == c)
        #expect(CanvasNavigation.destination(from: b, direction: .down,
                                             order: order, frames: frames) == d)
        #expect(CanvasNavigation.destination(from: c, direction: .up,
                                             order: order, frames: frames) == a)
    }

    @Test("Down cannot skip to a neighbouring column because its top is closer")
    func keepsTheCurrentVisualLane() {
        let origin = CanvasItemID.object(ObjectID())
        let directlyBelow = CanvasItemID.object(ObjectID())
        let besideAndLower = CanvasItemID.object(ObjectID())
        let frames: [CanvasItemID: CGRect] = [
            origin: CGRect(x: 0, y: 0, width: 90, height: 240),
            directlyBelow: CGRect(x: 0, y: 254, width: 90, height: 80),
            besideAndLower: CGRect(x: 110, y: 100, width: 90, height: 140)
        ]

        #expect(CanvasNavigation.destination(
            from: origin,
            direction: .down,
            order: [origin, besideAndLower, directlyBelow],
            frames: frames
        ) == directlyBelow)
    }

    @Test("A list is one column, so up and down are one item")
    func movesThroughAList() {
        let ids = (0..<4).map { _ in CanvasItemID.object(ObjectID()) }
        var frames: [CanvasItemID: CGRect] = [:]
        for (index, id) in ids.enumerated() {
            frames[id] = CGRect(x: 0, y: CGFloat(index) * 40, width: 400, height: 38)
        }
        #expect(CanvasNavigation.columnCount(in: frames) == 1)
        #expect(CanvasNavigation.destination(from: ids[1], direction: .down,
                                             order: ids, frames: frames) == ids[2])
        #expect(CanvasNavigation.destination(from: ids[1], direction: .up,
                                             order: ids, frames: frames) == ids[0])
    }

    /// Only what has been laid out is measured, so the row below can be off
    /// screen when the key is pressed. Movement falls back to stepping by the
    /// number of columns rather than stalling.
    @Test("Movement still works before the destination has been measured")
    func fallsBackToColumnCount() {
        let grid = Grid()
        // Everything below the first row is unmeasured.
        var partial = grid.frames
        for id in grid.ids.dropFirst(3) { partial[id] = nil }

        #expect(CanvasNavigation.destination(from: grid.ids[1], direction: .down,
                                             order: grid.ids, frames: partial) == grid.ids[4])
    }

    @Test("Nothing moves on an empty canvas")
    func toleratesAnEmptyCanvas() {
        #expect(CanvasNavigation.destination(from: nil, direction: .down,
                                             order: [], frames: [:]) == nil)
        #expect(CanvasNavigation.columnCount(in: [:]) == 1)
    }

    @Test("Columns are counted by leading edge, so a partial last row is not miscounted")
    func countsColumns() {
        #expect(CanvasNavigation.columnCount(in: Grid().frames) == 3)
    }
}

/// The cursor, the selection, and the difference between them.
@MainActor
@Suite("Keyboard navigation")
struct KeyboardNavigationTests {

    /// A folder holding one subfolder and one object, which is the only shape
    /// in which the canvas shows a folder at all: subfolders are listed by the
    /// place that contains them.
    private func harnessInAFolder() async throws -> (TestModel, FolderSnapshot, FolderSnapshot) {
        let harness = try await TestModel()
        let model = harness.model
        await model.createFolder(named: "Papers", in: nil)
        let papers = try #require(model.folderTree.first?.folder)

        model.navigate(to: .scope(.folder(papers.id)))
        await model.refreshContents()
        await model.createFolder(named: "Drafts", in: papers.id)
        try await harness.importFile(named: "one.txt")
        await model.refreshContents()

        let drafts = try #require(model.contents.folders.first)
        return (harness, papers, drafts)
    }

    /// Three objects in a known order, so a step has somewhere to land.
    private func harnessWithThreeObjects() async throws -> TestModel {
        let harness = try await TestModel()
        harness.model.navigate(to: .scope(.inbox))
        try await harness.importFile(named: "one.txt", contents: "one")
        try await harness.importFile(named: "two.txt", contents: "two")
        try await harness.importFile(named: "three.txt", contents: "three")
        return harness
    }

    @Test("The first arrow key enters the canvas and selects what it lands on")
    func entersTheCanvas() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model
        let first = try #require(model.canvasOrder.first)

        #expect(model.cursor == nil)
        model.moveCursor(.down)
        #expect(model.cursor == first)
        #expect(model.selection == Set([first.objectID].compactMap { $0 }))
    }

    @Test("Arrowing on carries the selection with it")
    func movesTheSelection() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model
        let order = model.canvasOrder

        model.moveCursor(.right)
        model.moveCursor(.right)
        #expect(model.cursor == order[1])
        #expect(model.selection == Set([order[1].objectID].compactMap { $0 }))
        #expect(model.selection.count == 1)
    }

    /// Shift measures from where the user started, not from whichever element
    /// an unordered set happens to hand back first.
    @Test("Shift extends the selection from the item it started on")
    func extendsFromTheAnchor() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model
        let order = model.canvasOrder

        model.moveCursor(.right)                              // first item
        model.moveCursor(.right, extendingSelection: true)    // and the second
        #expect(model.selection.count == 2)

        model.moveCursor(.right, extendingSelection: true)    // and the third
        #expect(model.selection.count == 3)
        #expect(model.cursor == order[2])

        // Coming back shrinks the range rather than growing it, because the
        // anchor has not moved.
        model.moveCursor(.left, extendingSelection: true)
        #expect(model.selection.count == 2)
    }

    @Test("Home and End reach the ends of the canvas")
    func reachesTheEnds() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model
        let order = model.canvasOrder

        model.moveCursorToEdge(.down)
        #expect(model.cursor == order.last)

        model.moveCursorToEdge(.up)
        #expect(model.cursor == order.first)
    }

    /// A folder is a place rather than a thing, so the cursor can rest on one
    /// while the selection — which is what the batch actions are handed —
    /// stays empty.
    @Test("The cursor rests on a folder without selecting it")
    func doesNotSelectFolders() async throws {
        let (harness, _, drafts) = try await harnessInAFolder()
        defer { harness.cleanUp() }
        let model = harness.model

        let object = try #require(model.contents.objects.first)
        model.select(object.id, modifiers: [])
        #expect(model.selection == [object.id])

        // Folders lead the canvas, so the top of it is the subfolder.
        model.moveCursorToEdge(.up)
        #expect(model.cursor == .folder(drafts.id))
        #expect(model.selection.isEmpty)
    }

    @Test("Return on a folder enters it")
    func opensAFolder() async throws {
        let (harness, _, drafts) = try await harnessInAFolder()
        defer { harness.cleanUp() }
        let model = harness.model

        model.cursor = .folder(drafts.id)
        await model.openCursorItem()
        #expect(model.scope == .folder(drafts.id))
    }

    @Test("Return on an object opens it into preview")
    func opensAnObject() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model

        model.moveCursor(.down)
        let id = try #require(model.cursor?.objectID)
        await model.openCursorItem()
        #expect(model.previewedObjectID == id)
    }

    /// Space is Quick Look. A folder has nothing to preview, so it does
    /// nothing rather than opening something that was not asked for.
    @Test("Quick Look asks for an object, not a place")
    func quickLooksObjectsOnly() async throws {
        let (harness, _, drafts) = try await harnessInAFolder()
        defer { harness.cleanUp() }
        let model = harness.model

        model.cursor = .folder(drafts.id)
        #expect(!model.canQuickLookCursorItem)
        model.previewCursorItem()
        #expect(model.previewedObjectID == nil)

        model.cursor = .object(try #require(model.contents.objects.first).id)
        #expect(model.canQuickLookCursorItem)
        model.previewCursorItem()
        #expect(model.previewedObjectID != nil)
    }

    /// Deleting what the cursor was resting on has to leave the cursor
    /// somewhere real, or the next arrow key starts from a ghost.
    @Test("The cursor lets go of anything that leaves the canvas")
    func releasesVanishedItems() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model

        model.moveCursor(.down)
        let id = try #require(model.cursor?.objectID)
        await model.delete([id])
        #expect(model.cursor == nil)
    }

    @Test("Changing place puts the cursor away")
    func clearsOnNavigation() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model

        model.moveCursor(.down)
        #expect(model.cursor != nil)

        model.navigate(to: .scope(.allObjects))
        #expect(model.cursor == nil)
    }

    /// Enclosing Folder climbs the tree; Back retraces where the user has
    /// been. From a root folder, the step up is to the library itself.
    @Test("Enclosing Folder climbs out of a folder")
    func climbsOut() async throws {
        let (harness, papers, drafts) = try await harnessInAFolder()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .scope(.folder(drafts.id)))
        await model.refreshContents()
        #expect(model.canGoToEnclosingScope)

        // One level up is the folder that contains this one.
        model.goToEnclosingScope()
        await model.refreshContents()
        #expect(model.scope == .folder(papers.id))
        // The way back down is one key press: the cursor waits on the folder
        // that was just left.
        #expect(model.cursor == .folder(drafts.id))

        // And from a root folder, the step up is the library itself.
        model.goToEnclosingScope()
        #expect(model.destination == .home)
    }

    @Test("There is nowhere to climb to from a place that is not a folder")
    func staysPutOutsideFolders() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        #expect(!harness.model.canGoToEnclosingScope)
    }

    // MARK: Moving between the columns

    @Test("Tab hands the keyboard to the other column, and back")
    func tabsBetweenColumns() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.keyboardPane == .sidebar)
        model.focusOtherPane()
        #expect(model.keyboardPane == .canvas)
        model.focusOtherPane()
        #expect(model.keyboardPane == .sidebar)
    }

    /// Asking for a column that is already listening still has to count: the
    /// window's first responder can have moved even when the pane has not.
    @Test("Asking twice for the same column still asks")
    func focusRequestsAlwaysCount() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        let before = model.keyboardFocusRequest
        model.focus(.sidebar)
        model.focus(.sidebar)
        #expect(model.keyboardFocusRequest == before + 2)
    }

    @Test("Right opens a closed folder rather than leaving the sidebar")
    func rightOpensAFolder() async throws {
        let (harness, papers, _) = try await harnessInAFolder()
        defer { harness.cleanUp() }
        let model = harness.model

        model.focus(.sidebar)
        model.navigate(to: .scope(.folder(papers.id)))
        await model.refreshContents()
        #expect(!model.expandedFolders.contains(papers.id))

        model.expandOrEnterCanvas()
        #expect(model.expandedFolders.contains(papers.id))
        // Still in the sidebar: there was something to open here.
        #expect(model.keyboardPane == .sidebar)
    }

    /// With nothing left to open, right carries on the way it was pointing.
    @Test("Right on a folder with nothing left to open steps into the canvas")
    func rightStepsIntoTheCanvas() async throws {
        let (harness, papers, _) = try await harnessInAFolder()
        defer { harness.cleanUp() }
        let model = harness.model

        model.focus(.sidebar)
        model.navigate(to: .scope(.folder(papers.id)))
        await model.refreshContents()
        model.expandOrEnterCanvas()          // opens it
        let entries = model.canvasEntryRequest
        model.expandOrEnterCanvas()          // nothing left to open

        #expect(model.keyboardPane == .canvas)
        #expect(model.canvasEntryRequest == entries + 1)
    }

    @Test("Left closes an open folder, then climbs to the one above")
    func leftClosesThenClimbs() async throws {
        let (harness, papers, drafts) = try await harnessInAFolder()
        defer { harness.cleanUp() }
        let model = harness.model

        model.focus(.sidebar)
        model.expandedFolders.insert(papers.id)
        model.navigate(to: .scope(.folder(papers.id)))
        await model.refreshContents()

        model.collapseOrGoToParent()
        #expect(!model.expandedFolders.contains(papers.id))

        // A closed folder has nothing to shut, so left goes up instead — and
        // from a child that means the folder containing it.
        model.navigate(to: .scope(.folder(drafts.id)))
        await model.refreshContents()
        model.collapseOrGoToParent()
        #expect(model.scope == .folder(papers.id))
    }

    /// Stepping across into a canvas with nothing lit looks exactly like the
    /// key having done nothing.
    @Test("Arriving in the canvas lights something up")
    func arrivingLightsSomething() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model

        model.focus(.sidebar)
        #expect(model.cursor == nil)

        model.enterCanvas()
        model.lightFirstItemIfNothingIsLit()
        #expect(model.cursor == model.canvasOrder.first)
    }

    /// A click means "select nothing" as readily as it means "select this", so
    /// arriving must not overrule a cursor that is already placed.
    @Test("Arriving does not move a cursor that is already somewhere")
    func arrivingLeavesAPlacedCursorAlone() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model

        model.moveCursor(.down)
        model.moveCursor(.right)
        let placed = model.cursor
        #expect(placed == model.canvasOrder[1])

        model.lightFirstItemIfNothingIsLit()
        #expect(model.cursor == placed)
    }

    /// Left runs out of canvas at the first item, and says so, which is what
    /// lets the view step back into the sidebar instead.
    @Test("Left reports going nowhere once it reaches the first item")
    func reportsRunningOutOfCanvas() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.moveCursor(.right))          // onto the first item
        #expect(!model.moveCursor(.left))          // nowhere further left
        #expect(model.cursor == model.canvasOrder.first)
    }

    /// Shift-clicking and shift-arrowing are the same rule, so the two cannot
    /// disagree about where a range starts.
    @Test("Shift-clicking extends from the item that was clicked first")
    func clickAndKeyboardShareOneAnchor() async throws {
        let harness = try await harnessWithThreeObjects()
        defer { harness.cleanUp() }
        let model = harness.model
        let objects = model.contents.objects

        model.select(objects[0].id, modifiers: [])
        #expect(model.selection == [objects[0].id])

        model.select(objects[2].id, modifiers: .shift)
        #expect(model.selection.count == 3)
        #expect(model.cursor == .object(objects[2].id))
    }
}

#if os(macOS)
import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
import NookLibrary
@testable import Nook

/// The canvas in a window that is never shown, made wide and then narrow
/// again — the one thing a Folders First grid used to refuse to do.
@MainActor
@Suite("Gallery resizing", .serialized)
struct GalleryResizeTests {

    @Test("A Folders First grid follows the window back down in width")
    func foldersFirstGridShrinksWithTheWindow() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        await model.createFolder(named: "Work", in: nil)
        for index in 0..<12 {
            _ = try await harness.importFile(named: "photo-\(index).png", as: .png)
        }
        await model.setViewMode(.grid)
        await model.setFoldersFirst(true)
        await model.refreshAll()
        #expect(model.foldersFirst && model.viewMode == .grid)
        #expect(!model.contents.folders.isEmpty)

        let hosting = try await hostCanvas(model, width: 1100)
        #expect(widestSubview(in: hosting) <= 1100.5)

        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        await settle(hosting)
        let widest = widestSubview(in: hosting)
        #expect(widest <= 600.5, "canvas content reaches \(widest)pt in a 600pt window")
    }

    @Test("A plain grid follows the window back down in width")
    func adaptiveGridShrinksWithTheWindow() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        for index in 0..<12 {
            _ = try await harness.importFile(named: "photo-\(index).png", as: .png)
        }
        await model.setViewMode(.grid)
        await model.setFoldersFirst(false)
        await model.refreshAll()

        let hosting = try await hostCanvas(model, width: 1100)
        hosting.frame.size.width = 600
        await settle(hosting)
        let widest = widestSubview(in: hosting)
        #expect(widest <= 600.5, "canvas content reaches \(widest)pt in a 600pt window")
    }

    @Test("A size chosen in a location following the default survives a change of view")
    func itemScaleSurvivesSwitchingViews() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        _ = try await harness.importFile(named: "photo.png", as: .png)
        await model.setViewMode(.grid)
        await model.refreshAll()
        #expect(!model.isRememberingLocation)

        model.setItemScale(2)
        await model.commitItemScale()
        #expect(model.itemScale == 2)

        // Switching views rewrites the global default, and a location
        // following it reloads from there — which is where the size used
        // to be lost.
        await model.setViewMode(.list)
        await model.loadPreferences()
        #expect(model.itemScale == 2, "size fell back to \(model.itemScale) after switching views")
    }

    // MARK: Hosting

    /// The canvas at a width the test dictates. The app's window sets its
    /// own floor; here the hosting view is simply handed a frame and expected
    /// to keep to it, the way a window being dragged narrower hands its
    /// content a width.
    private func hostCanvas(_ model: LibraryModel, width: CGFloat) async throws -> NSHostingView<BrowseView> {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: BrowseView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let container = NSView(frame: hosting.frame)
        container.addSubview(hosting)
        window.contentView = container
        await settle(hosting)
        return hosting
    }

    /// Lets SwiftUI lay the canvas out again: sleeping hands the main run
    /// loop back, which is where geometry changes and their state land.
    private func settle(_ view: NSView) async {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The right-most edge any view in the tree reaches, in the hosting
    /// view's coordinates.
    private func widestSubview(in root: NSView) -> CGFloat {
        var maxX: CGFloat = 0
        func walk(_ view: NSView) {
            // A scroller AppKit has hidden keeps whatever frame it last had.
            guard !view.isHidden, !(view is NSScroller) else { return }
            maxX = max(maxX, view.convert(view.bounds, to: root).maxX)
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return maxX
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
import NookLibrary
@testable import Nook

/// The preview in a window that is never shown: photos fit and zoom with
/// AppKit's own magnification, and the pages it swipes between stay in step
/// with the object the model says is open.
@MainActor
@Suite("Preview viewer", .serialized)
struct PreviewViewerTests {

    @Test("A photo opens fitted to the view and can be zoomed in from there")
    func photoFitsAndZooms() async throws {
        let url = try Self.writePNG(width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = ZoomableImageView.ZoomingScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = view
        view.load(url)
        try await Self.settle(until: { view.documentView?.frame.width == 200 }, view)

        #expect(view.allowsMagnification)
        #expect(abs(view.magnification - 2) < 0.001, "fitted at \(view.magnification)")
        #expect(abs(view.minMagnification - 1) < 0.001, "100% is still reachable")
        #expect(view.maxMagnification >= 6)

        view.magnification = 5
        #expect(abs(view.magnification - 5) < 0.001)
    }

    @Test("Stepping from the keyboard or the menu bar moves the pages")
    func pagesFollowTheModel() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .scope(.inbox))
        for index in 0..<3 {
            try await harness.importFile(named: "page-\(index).png", as: .png)
        }
        await model.refreshAll()
        let objects = model.visibleObjects
        #expect(objects.count == 3)
        model.previewedObjectID = objects[1].id

        let width: CGFloat = 600
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // A window that is never shown never runs an animation, so the pages
        // are made to move at once.
        let hosting = NSHostingView(rootView: BrowseView(model: model)
            .transaction { $0.animation = nil })
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 500)
        window.contentView = hosting
        try await Self.settle(until: { Self.pager(in: hosting) != nil }, hosting)

        let pager: NSScrollView = try #require(Self.pager(in: hosting))
        let page = pager.contentView.bounds.width
        #expect(abs(pager.contentView.bounds.minX - page) < 1,
                "opened on page \(pager.contentView.bounds.minX / page)")

        model.stepPreview(1)
        try await Self.settle(until: { abs(pager.contentView.bounds.minX - 2 * page) < 1 }, hosting)
        #expect(abs(pager.contentView.bounds.minX - 2 * page) < 1)

        // What sits under the pointer on a photo page is the photo's own
        // zooming view, which hands swipes on to these pages until zoomed.
        let center = NSPoint(x: pager.bounds.midX, y: pager.bounds.midY)
        let target = try #require(window.contentView?.hitTest(pager.convert(center, to: nil)))
        #expect(target.enclosingScrollView is ZoomableImageView.ZoomingScrollView)
    }

    @Test("A swipe over a photo shown whole goes on to the pages; a zoomed-in photo pans instead")
    func photoHandsSwipesOn() async throws {
        let url = try Self.writePNG(width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let pages = SwipeRecorder(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let view = ZoomableImageView.ZoomingScrollView(frame: pages.bounds)
        pages.addSubview(view)
        window.contentView = pages
        view.load(url)
        try await Self.settle(until: { view.documentView?.frame.width == 200 }, view)

        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                         wheelCount: 2, wheel1: 0, wheel2: 40, wheel3: 0))
        let swipe = try #require(NSEvent(cgEvent: event))
        view.scrollWheel(with: swipe)
        #expect(pages.swipes == 1)

        view.magnification = 5
        view.scrollWheel(with: swipe)
        #expect(pages.swipes == 1, "a zoomed-in photo keeps the swipe to pan itself")
    }

    @Test("Photos' keys: Esc and Space close, Option-Space plays, the arrows step, Z and Command-Plus and -Minus zoom")
    func keys() throws {
        func key(_ code: UInt16, _ characters: String,
                 _ modifiers: NSEvent.ModifierFlags = []) throws -> PreviewKey? {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            return PreviewKeyMonitor.Coordinator.key(for: event)
        }
        #expect(try key(53, "\u{1b}") == .escape)
        #expect(try key(49, " ") == .space)
        #expect(try key(49, " ", .option) == .playPause)
        // Arrow keys always carry these two flags; they are not modifiers.
        #expect(try key(123, "\u{F702}", [.numericPad, .function]) == .step(-1))
        #expect(try key(124, "\u{F703}", [.numericPad, .function]) == .step(1))
        #expect(try key(6, "z") == .zoomToActualSize)
        #expect(try key(24, "=", .command) == .zoom(1))
        #expect(try key(27, "-", .command) == .zoom(-1))
        // Command-Arrow is the menu bar's Previous and Next Item.
        #expect(try key(124, "\u{F703}", [.command, .numericPad, .function]) == nil)
        #expect(try key(6, "z", .command) == nil)
    }

    @Test("Z goes to 100% and back; Command-Plus and -Minus zoom within the photo's limits")
    func zoomKeys() async throws {
        let url = try Self.writePNG(width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = ZoomableImageView.ZoomingScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = view
        view.load(url)
        try await Self.settle(until: { view.documentView?.frame.width == 200 }, view)
        #expect(abs(view.magnification - 2) < 0.001)

        // The zoom animates, as it does in Photos; each step waits it out.
        func expectZoom(_ expected: @autoclosure () -> CGFloat, after change: () -> Void,
                        _ comment: Comment) async throws {
            change()
            try await Self.settle(until: { abs(view.magnification - expected()) < 0.001 }, view)
            #expect(abs(view.magnification - expected()) < 0.001, "\(comment): \(view.magnification)")
        }
        try await expectZoom(1, after: view.toggleActualSize, "Z goes to 100%")
        try await expectZoom(2, after: view.toggleActualSize, "Z again goes back")
        try await expectZoom(3, after: { view.zoom(by: 1) }, "Command-Plus zooms in")
        try await expectZoom(2, after: { view.zoom(by: -5) },
                             "never smaller than fitted")
    }

    @Test("Double-clicking a photo goes back; a single click does not")
    func doubleClickCloses() throws {
        let view = ZoomableImageView.ZoomingScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        var closed = 0
        view.onClose = { closed += 1 }
        func click(_ count: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 200),
                                            modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, eventNumber: 0, clickCount: count,
                                            pressure: 1))
        }
        view.mouseDown(with: try click(1))
        #expect(closed == 0)
        view.mouseDown(with: try click(2))
        #expect(closed == 1)
    }

    private final class SwipeRecorder: NSView {
        var swipes = 0
        override func scrollWheel(with event: NSEvent) { swipes += 1 }
    }

    // MARK: Helpers

    /// SwiftUI's own horizontal scroll view — the pages — rather than a
    /// photo's zooming one inside it.
    private static func pager(in root: NSView) -> NSScrollView? {
        if let scroll = root as? NSScrollView, !(scroll is ZoomableImageView.ZoomingScrollView),
           let document = scroll.documentView,
           document.frame.width > scroll.contentView.bounds.width * 1.5 {
            return scroll
        }
        for subview in root.subviews {
            if let found = pager(in: subview) { return found }
        }
        return nil
    }

    private static func writePNG(width: Int, height: Int) throws -> URL {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appending(path: "preview-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    private static func settle(until condition: () -> Bool, _ view: NSView) async throws {
        for _ in 0..<60 where !condition() {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        view.layoutSubtreeIfNeeded()
    }
}
#endif

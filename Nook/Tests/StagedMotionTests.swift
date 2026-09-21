#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Nook

/// A grid losing one of its tiles, shaped the way the canvas is (a scroll
/// view, the place swap, the arrangement swap, a lazy grid): the tile that is
/// leaving must fade where it stands while the rest hold their places, and
/// only once it has gone may they close the gap.
///
/// What is watched is what is drawn — the presentation layers Core Animation
/// is actually showing — since layout reports a target the moment it is set.
/// Nothing renders in a window that is off screen, so this one is on screen
/// but fully transparent and never key.
@MainActor
@Suite("Staged motion", .serialized)
struct StagedMotionTests {

    struct Grid: View {
        let ids: [Int]
        let change: MotionChoreography

        var body: some View {
            ScrollView {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        ZStack(alignment: .top) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 10)],
                                      spacing: 10) {
                                ForEach(ids, id: \.self) { id in
                                    Color(red: 0, green: 0, blue: 1)
                                        .frame(width: 40, height: 40)
                                        .transition(change.itemTransition(reduceMotion: false))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .transition(.staged(reduceMotion: false))
                        }
                        .animation(NookMotion.reflow, value: 0)
                    }
                    .padding(.horizontal, 20)
                    .animation(change.shift(reduceMotion: false), value: ids)
                    .id(1)
                    .transition(.staged(reduceMotion: false))
                }
            }
        }
    }

    @MainActor
    @Observable
    final class State {
        var ids = [1, 2, 3, 4]
        var change = MotionChoreography.none

        func show(_ next: [Int]) {
            change = MotionChoreography(from: ids, to: next)
            ids = next
        }
    }

    struct Host: View {
        let state: State
        var body: some View { Grid(ids: state.ids, change: state.change) }
    }

    /// Every blue tile being drawn right now, as (x, opacity) in window
    /// coordinates, left to right.
    private func tiles(in view: NSView) -> [(x: CGFloat, opacity: Float)] {
        var found: [(CGFloat, Float)] = []
        func walk(_ layer: CALayer) {
            let shown = layer.presentation() ?? layer
            if let components = shown.backgroundColor?.components, components.count >= 3,
               components[0] < 0.1, components[1] < 0.1, components[2] > 0.9 {
                var opacity: Float = 1
                var frame = shown.frame
                var current: CALayer? = shown
                while let layer = current {
                    opacity *= layer.opacity
                    if let parent = layer.superlayer { frame = layer.convert(frame, to: parent) }
                    current = layer.superlayer
                }
                found.append((frame.minX, opacity))
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
        if let layer = view.layer { walk(layer) }
        return found.sorted { $0.0 < $1.0 }
    }

    @Test("A leaving tile fades in place; the rest close up only once it has gone")
    func survivorsWaitForTheExit() async throws {
        let state = State()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: Host(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(50)) }
        // The grid centres its columns in the width it is given, so the
        // tiles are read relative to the first rather than to the window.
        let before = tiles(in: hosting)
        #expect(before.count == 4, "before: \(before)")
        let origin = before.first?.x ?? 0
        func x(_ tile: (x: CGFloat, opacity: Float)) -> CGFloat { tile.x - origin }
        #expect(before.map(x) == [0, 100, 200, 300], "before: \(before)")

        state.show([1, 3, 4])
        try? await Task.sleep(for: .milliseconds(80))
        let leaving = tiles(in: hosting)
        // Tile 2 is still there, part-way through its fade; 3 and 4 have not moved.
        #expect(leaving.count == 4, "during exit: \(leaving)")
        #expect(leaving.count == 4 && leaving[1].opacity < 0.9 && leaving[1].opacity > 0, "during exit: \(leaving)")
        #expect(leaving.count == 4 && x(leaving[2]) == 200 && x(leaving[3]) == 300, "during exit: \(leaving)")

        try? await Task.sleep(for: .milliseconds(170))
        let closing = tiles(in: hosting)
        // Tiles 3 and 4 are on their way now.
        let survivors = closing.filter { $0.opacity > 0.5 }
        #expect(survivors.count == 3, "during shift: \(closing)")
        #expect(survivors.count == 3 && x(survivors[1]) < 200 && x(survivors[1]) > 100, "during shift: \(closing)")

        try? await Task.sleep(for: .milliseconds(400))
        let settled = tiles(in: hosting)
        #expect(settled.map(x) == [0, 100, 200], "settled: \(settled)")
        #expect(settled.allSatisfy { $0.opacity == 1 }, "settled: \(settled)")
    }
}
#endif

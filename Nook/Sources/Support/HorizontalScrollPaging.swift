#if os(macOS)
import AppKit
import SwiftUI

/// Turns a trackpad swipe or a mouse's horizontal scroll wheel into a step
/// through whatever is being paged — the pointer's equivalent of the arrow
/// keys, for whichever hand is already on it.
///
/// `QLPreviewView` scrolls and zooms its own content on both axes, so this
/// only ever acts once a delta reads as mostly horizontal, and it lets every
/// other scroll event travel on to the preview untouched underneath it.
struct HorizontalScrollPaging: NSViewRepresentable {
    let isActive: Bool
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onStep = onStep
        context.coordinator.window = view.window
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var isActive = false
        var onStep: ((Int) -> Void)?
        weak var window: NSWindow?
        private var monitor: Any?
        private var accumulatedX: CGFloat = 0
        private var hasSteppedThisGesture = false

        /// How far a trackpad swipe has to travel before it counts as
        /// deliberate paging rather than the tail end of a vertical scroll.
        private let threshold: CGFloat = 80

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard isActive, let window, event.window === window else { return }
            guard event.scrollingDeltaX != 0,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            else { return }

            // A plain scroll-wheel mouse reports every tick with no phase at
            // all; each one is its own gesture rather than a fragment of a
            // continuous trackpad swipe.
            guard event.hasPreciseScrollingDeltas else {
                step(for: event.scrollingDeltaX)
                return
            }

            if event.phase.contains(.began) {
                accumulatedX = 0
                hasSteppedThisGesture = false
            }
            guard !hasSteppedThisGesture else { return }
            accumulatedX += event.scrollingDeltaX
            guard abs(accumulatedX) > threshold else { return }
            hasSteppedThisGesture = true
            step(for: accumulatedX)
        }

        /// Swiping or scrolling left brings in what comes next, the same
        /// direction Photos and Safari's tab strip already treat it as.
        private func step(for deltaX: CGFloat) {
            onStep?(deltaX < 0 ? 1 : -1)
        }
    }
}
#endif

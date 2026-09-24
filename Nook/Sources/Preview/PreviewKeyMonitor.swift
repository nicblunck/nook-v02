#if os(macOS)
import AppKit
import SwiftUI

/// The keys Photos answers to while a photo is open, as a preview sees them.
enum PreviewKey: Equatable {
    /// Esc: back to the gallery.
    case escape
    /// Space: back to the gallery too, except where a web page scrolls.
    case space
    /// Option-Space: play or pause a video.
    case playPause
    /// Left or Right Arrow: the previous or next object.
    case step(Int)
    /// Z: between the current zoom and 100%.
    case zoomToActualSize
    /// Command-Plus and Command-Minus.
    case zoom(Int)
}

/// Hears the preview's keys whatever inside it has been clicked into.
///
/// A `PDFView`, `AVPlayerView` or `QLPreviewView` that has been clicked
/// takes the keyboard, and SwiftUI's `onKeyPress` above it then never hears
/// a thing — but Photos' keys work no matter where the last click landed. So
/// they are read off the window before they reach any of those views. Typing
/// in a field, and anything in another window such as the info popover, is
/// left alone.
struct PreviewKeyMonitor: NSViewRepresentable {
    let onKey: (PreviewKey) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var onKey: ((PreviewKey) -> Bool)?
        weak var view: NSView?
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window = view?.window, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSText),
                  let key = Self.key(for: event)
            else { return false }
            return onKey?(key) ?? false
        }

        static func key(for event: NSEvent) -> PreviewKey? {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let character = event.charactersIgnoringModifiers?.lowercased()
            switch (event.keyCode, modifiers) {
            case (53, []): return .escape
            case (49, []): return .space
            case (49, .option): return .playPause
            case (123, []): return .step(-1)
            case (124, []): return .step(1)
            default: break
            }
            switch (character, modifiers) {
            case ("z", []): return .zoomToActualSize
            case ("=", .command), ("+", .command), ("+", [.command, .shift]): return .zoom(1)
            case ("-", .command): return .zoom(-1)
            default: return nil
            }
        }
    }
}
#endif

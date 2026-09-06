#if os(macOS)
import AppKit
import SwiftUI

/// Gets in front of a focused list for the few keys the sidebar means
/// something particular by.
///
/// The sidebar's list has to *keep* the keyboard: that is what makes macOS
/// paint its own selection — full width, right shape, labels and symbols
/// contrasted for it — and drawing that by hand is what leaves a sidebar
/// unable to say where the keyboard is. But a focused list answers the arrows
/// itself, down in AppKit, before SwiftUI's key handling is offered any of
/// them. `onKeyPress` only ever sees what the list declined, and it declines
/// nothing.
///
/// A local monitor runs before the event reaches the responder chain at all,
/// which is the only place left to stand. It is scoped to its own window, and
/// to the moments the sidebar actually wants those keys, so it never swallows
/// a keystroke meant for anything else.
struct WindowKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    /// True when the key was dealt with and must not travel any further.
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onKey = onKey
        context.coordinator.window = view.window
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var isActive = false
        var onKey: ((NSEvent) -> Bool)?
        /// Scoped to one window, so a background window can never eat the
        /// front one's keys.
        weak var window: NSWindow?
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive,
                      let window = self.window, event.window === window,
                      self.onKey?(event) == true
                else { return event }
                return nil
            }
        }

        /// Called from `dismantleNSView`, which is what SwiftUI guarantees to
        /// run when the sidebar goes.
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// The keys a sidebar answers, by code rather than by character: a key's
/// character depends on the keyboard layout, and its position does not.
enum MacKey {
    static let `return`: UInt16 = 36
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let left: UInt16 = 123
    static let right: UInt16 = 124
}

extension NSEvent {
    /// The modifiers the person is actually holding down.
    ///
    /// The keys a list navigates by — the arrows, Home, End, Page Up and Page
    /// Down — arrive with `.function` and `.numericPad` already set, because
    /// that is how the keyboard reports them, not because anything is being
    /// held. A handler that asks whether *no* modifier is down has to discount
    /// them or it can never answer an arrow at all. Caps Lock goes with them:
    /// it is a state the keyboard is in, not a key held for this press.
    var heldModifiers: NSEvent.ModifierFlags {
        modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
    }
}
#endif

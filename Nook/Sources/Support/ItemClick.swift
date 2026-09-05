import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// One click, as the window server reports it.
///
/// AppKit does not hold the first click back to find out whether a second is
/// coming. It acts at once, and when a second click arrives that event says it
/// is the second. That is why selection in Finder lands the instant the mouse
/// comes up, and why pairing a single-tap gesture with a double-tap one cannot
/// match it: the pair has to be told apart before either is allowed to fire,
/// which costs a double-click interval every time.
struct Click: Equatable {
    var count: Int
    var modifiers: EventModifiers

    var isDoubleClick: Bool { count >= 2 }

    /// The click being dispatched right now, or a plain single click when
    /// there is no mouse event to read.
    @MainActor
    static var current: Click {
        #if canImport(AppKit)
        guard let event = NSApp.currentEvent else { return Click(count: 1, modifiers: []) }
        return Click(event: event)
        #else
        return Click(count: 1, modifiers: [])
        #endif
    }
}

#if canImport(AppKit)
extension Click {
    /// `clickCount` throws on anything that is not a mouse event, and reports
    /// zero for a button held past the click threshold — which is still one
    /// click as far as the interface is concerned.
    init(event: NSEvent) {
        let isMouseEvent = switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            true
        default:
            false
        }

        var modifiers: EventModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }

        self.init(count: isMouseEvent ? max(event.clickCount, 1) : 1, modifiers: modifiers)
    }
}
#endif

/// Telling "which one" apart from "open it", the way each platform does.
///
/// The spec asks for native behaviour on both, and the two platforms do not
/// agree: a Mac separates selecting from opening, while a tap on iOS opens.
struct ItemClick: ViewModifier {
    var select: (EventModifiers) -> Void = { _ in }
    var open: () -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        // One gesture, so nothing has to be disambiguated before it can fire.
        content.onTapGesture {
            let click = Click.current
            if click.isDoubleClick { open() } else { select(click.modifiers) }
        }
        #else
        content.onTapGesture { open() }
        #endif
    }
}

extension View {
    func itemClick(
        select: @escaping (EventModifiers) -> Void = { _ in },
        open: @escaping () -> Void
    ) -> some View {
        modifier(ItemClick(select: select, open: open))
    }
}

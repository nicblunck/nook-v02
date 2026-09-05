import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

extension EventModifiers {
    /// The modifier keys held at this moment.
    ///
    /// A `TapGesture` does not carry them, and the alternative — a separate
    /// modifier-qualified gesture per combination — makes an unmodified click
    /// wait to find out which gesture it belongs to. Reading the keys once,
    /// when the click lands, keeps selection immediate.
    @MainActor
    static var current: EventModifiers {
        #if canImport(AppKit)
        let flags = NSEvent.modifierFlags
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
        #else
        return []
        #endif
    }
}

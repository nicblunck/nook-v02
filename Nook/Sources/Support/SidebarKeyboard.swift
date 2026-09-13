#if os(macOS)
import AppKit
import SwiftUI

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

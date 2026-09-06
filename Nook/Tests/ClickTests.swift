import Foundation
import Testing
import AppKit
@testable import Nook

@Suite("Click")
struct ClickTests {

    private func mouseUp(clicks: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        ))
    }

    @Test("The first click of a pair is a single click and the second opens")
    func countsClicks() throws {
        #expect(Click(event: try mouseUp(clicks: 1)).isDoubleClick == false)
        #expect(Click(event: try mouseUp(clicks: 2)).isDoubleClick)
    }

    /// AppKit reports zero when the button was held past the click threshold.
    /// It is still one click as far as the interface is concerned, and it must
    /// never read as no click at all.
    @Test("A click held past the threshold still counts as one")
    func heldClickCountsAsOne() throws {
        let click = Click(event: try mouseUp(clicks: 0))
        #expect(click.count == 1)
        #expect(!click.isDoubleClick)
    }

    @Test("Modifiers come off the event that carried the click")
    func readsModifiers() throws {
        #expect(Click(event: try mouseUp(clicks: 1, modifiers: .command)).modifiers == .command)
        #expect(Click(event: try mouseUp(clicks: 1, modifiers: .shift)).modifiers == .shift)
        #expect(Click(event: try mouseUp(clicks: 1)).modifiers == [])
    }

    /// `clickCount` raises on anything that is not a mouse event, so the type
    /// has to be checked before it is read.
    @Test("A non-mouse event is read without asking it for a click count")
    func toleratesNonMouseEvents() throws {
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
        let click = Click(event: key)
        #expect(click.count == 1)
        #expect(click.modifiers == .command)
    }
}

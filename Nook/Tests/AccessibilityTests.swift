import Foundation
import Testing
import NookLibrary
@testable import Nook

/// What the interface conveys with a glyph, a tint or a bare number has to
/// reach a reader who gets none of those.
@MainActor
@Suite("Spoken descriptions")
struct AccessibilityTests {

    @Test("A count is spoken as a quantity rather than a bare number")
    func countsCarryTheirUnit() {
        // "Inbox, 12" leaves the 12 to be guessed at; it could as easily be
        // part of the name.
        #expect(Format.itemCount(12) == "12 items")
        #expect(Format.itemCount(1) == "1 item")
        #expect(Format.itemCount(0) == "0 items")
        #expect(Format.folderCount(1) == "1 folder")
        #expect(Format.folderCount(3) == "3 folders")
    }

    @Test("The separator that divides the caption on screen is not pronounced")
    func spokenCaptionDropsTheInterpunct() async throws {
        let test = try await TestModel()
        defer { test.cleanUp() }
        let object = try #require(try await test.importFile(named: "notes.txt"))

        #expect(Format.caption(for: object).contains("·"))
        #expect(!Format.spokenCaption(for: object).contains("·"))
        #expect(Format.spokenCaption(for: object).contains(", "))
    }

    @Test("A favourite is spoken, not only drawn")
    func favoriteReachesTheCaption() async throws {
        let test = try await TestModel()
        defer { test.cleanUp() }
        let object = try #require(try await test.importFile(named: "starred.txt"))

        #expect(!Format.spokenCaption(for: object).contains("Favorite"))

        await test.model.setFavorite(true, for: [object.id])
        let favorited = try #require(test.model.contents.objects.first { $0.id == object.id })

        // The star is drawn as an unlabelled glyph, so without this the row
        // sounds exactly like an unfavourited one.
        #expect(favorited.isFavorite)
        #expect(Format.spokenCaption(for: favorited).contains("Favorite"))
    }

    @Test("A locked object does not sound like an unprotected one")
    func lockedReachesTheCaption() async throws {
        let test = try await TestModel()
        defer { test.cleanUp() }
        let object = try #require(try await test.importFile(named: "sealed.txt"))

        try await test.model.library.service.setPrivacy(
            PrivacyFlags(isLocked: true),
            forObjects: [object.id]
        )
        await test.model.refreshContents()
        let locked = try #require(test.model.contents.objects.first { $0.id == object.id })

        #expect(locked.isLocked)
        #expect(Format.spokenCaption(for: locked).contains("Locked"))
    }
}

import Foundation
import Testing
@testable import NookLibrary

@Suite("Derived content")
struct DerivedContentTests {

    @Test("Text is extracted from a document and stored apart from the original")
    func extractsText() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "brief.txt", contents: "Concrete and daylight.")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)

        #expect(await harness.service.objectsAwaitingTextExtraction() == [id])
        #expect(try await harness.service.extractedText(for: id) == nil)

        await harness.service.extractPendingText()

        #expect(try await harness.service.extractedText(for: id) == "Concrete and daylight.")
        // Nothing left waiting, so a second pass is free.
        #expect(await harness.service.objectsAwaitingTextExtraction().isEmpty)
    }

    @Test("Nothing is queued for content that has no text to give")
    func skipsUnextractableKinds() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        _ = try await harness.service.importLink(
            #require(URL(string: "https://example.com")), into: .root
        )
        #expect(await harness.service.objectsAwaitingTextExtraction().isEmpty)
    }

    @Test("Extracted text is protected exactly as the original is")
    func extractedTextHonoursLocks() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "salary.txt", contents: "figures")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)
        await harness.service.extractPendingText()

        try await harness.service.setPrivacy(PrivacyFlags(isLocked: true), forObjects: [id])

        await #expect(throws: LibraryError.self) {
            _ = try await harness.service.extractedText(for: id)
        }

        // ...and comes back once the lock is authenticated.
        let authenticated = AccessContext().unlocking(.object(id))
        #expect(try await harness.service.extractedText(for: id, in: authenticated) == "figures")
    }

    @Test("Derived content can be discarded and rebuilt")
    func derivedContentIsRebuildable() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "notes.txt", contents: "rebuild me")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)
        await harness.service.extractPendingText()
        #expect(try await harness.service.extractedText(for: id) != nil)

        try await harness.service.discardDerivedContent()
        #expect(try await harness.service.extractedText(for: id) == nil)

        await harness.service.extractPendingText()
        #expect(try await harness.service.extractedText(for: id) == "rebuild me")

        // The original is untouched by any of it.
        let original = try #require(try await harness.service.originalURL(for: id))
        #expect(try Data(contentsOf: original) == Data("rebuild me".utf8))
    }
}

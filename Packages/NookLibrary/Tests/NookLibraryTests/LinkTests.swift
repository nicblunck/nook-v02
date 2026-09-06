import Foundation
import Testing
@testable import NookLibrary

@Suite("Links")
struct LinkTests {

    @Test("A link saved without page metadata is queued to be filled in later")
    func linksQueueForMetadata() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let url = try #require(URL(string: "https://example.com/typography"))
        let id = try await harness.service.importLink(url, into: .root)

        #expect(await harness.service.linksAwaitingMetadata() == [id])

        try await harness.service.applyLinkMetadata(
            LinkMetadata(title: "On Typography", summary: "A short essay."), to: id
        )

        let object = try #require(await harness.service.object(id))
        #expect(object.linkPageTitle == "On Typography")
        #expect(object.linkDescription == "A short essay.")
        // The placeholder title gave way to the real one.
        #expect(object.title == "On Typography")
        #expect(await harness.service.linksAwaitingMetadata().isEmpty)
    }

    @Test("A title the user has edited survives a later metadata fetch")
    func fetchDoesNotOverwriteAnEditedTitle() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let url = try #require(URL(string: "https://example.com/typography"))
        let id = try await harness.service.importLink(url, into: .root)
        try await harness.service.updateObject(id, title: "Read for the pitch")

        try await harness.service.applyLinkMetadata(LinkMetadata(title: "On Typography"), to: id)

        let object = try #require(await harness.service.object(id))
        #expect(object.title == "Read for the pitch")
        // The page's own title is still recorded, just not imposed.
        #expect(object.linkPageTitle == "On Typography")
    }

    @Test("A link that already carries metadata is not queued again")
    func enrichedLinksAreNotRequeued() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let url = try #require(URL(string: "https://example.com"))
        _ = try await harness.service.importLink(
            url, into: .root, metadata: LinkMetadata(title: "Example")
        )
        #expect(await harness.service.linksAwaitingMetadata().isEmpty)
    }
}

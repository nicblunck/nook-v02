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

    @Test("A link preview is advertised so another device can rebuild its cache")
    func previewImagesAreRebuiltPerDevice() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let url = try #require(URL(string: "https://example.com/typography"))
        let id = try await harness.service.importLink(url, into: .root)
        try await harness.service.applyLinkMetadata(
            LinkMetadata(title: "On Typography", previewImageURL: url), to: id
        )

        #expect(await harness.service.linksAwaitingMetadata().isEmpty)
        #expect(await harness.service.linksAdvertisingPreviewImage() == [id])
    }

    @Test("A link preview's dimensions drive its aspect ratio")
    func previewDimensionsArePersisted() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let url = try #require(URL(string: "https://example.com/typography"))
        let id = try await harness.service.importLink(url, into: .root)
        try await harness.service.applyLinkMetadata(
            LinkMetadata(
                title: "On Typography",
                previewImageURL: url,
                previewPixelWidth: 1_200,
                previewPixelHeight: 630
            ),
            to: id
        )

        let object = try #require(await harness.service.object(id))
        #expect(object.pixelWidth == 1_200)
        #expect(object.pixelHeight == 630)
        #expect(object.aspectRatio == 1_200.0 / 630.0)
    }

    @Test("A link without a representative image is not queued for preview rebuilding")
    func linksWithoutPreviewImagesAreNotRequeued() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let url = try #require(URL(string: "https://example.com/typography"))
        _ = try await harness.service.importLink(
            url, into: .root, metadata: LinkMetadata(title: "On Typography")
        )

        #expect(await harness.service.linksAdvertisingPreviewImage().isEmpty)
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

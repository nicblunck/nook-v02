import Foundation
import Testing
@testable import NookLibrary

@Suite("Tool surface")
struct ToolSurfaceTests {

    private func makeLibrary() async throws -> (TestLibrary, LibraryToolSurface) {
        let harness = try await TestLibrary()
        return (harness, LibraryToolSurface(service: harness.service))
    }

    @Test("Search returns references that resolve back to the same objects")
    func searchReturnsResolvableReferences() async throws {
        let (harness, surface) = try await makeLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "brutalism.txt", contents: "concrete")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)

        let results = await surface.searchObjects(.init(query: "brutalism"))
        let digest = try #require(results.first)
        #expect(digest.reference == "object://\(id.uuid.uuidString)")

        let fetched = try #require(await surface.getObject(reference: digest.reference))
        #expect(fetched.title == "brutalism")
    }

    @Test("Hidden content is unreachable through every tool")
    func hiddenContentIsUnreachable() async throws {
        let (harness, surface) = try await makeLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "Private")
        let source = try harness.makeSourceFile(named: "secret.txt", contents: "secret")
        let report = await harness.service.importItems([.file(url: source)], into: .folder(folder.id))
        let id = try #require(report.importedIDs.first)
        let reference = "object://\(id.uuid.uuidString)"

        try await harness.service.addTag(named: "private", to: [id])
        try await harness.service.setPrivacy(PrivacyFlags(isHidden: true), forFolder: folder.id)

        #expect(await surface.searchObjects(.init(query: "secret")).isEmpty)
        #expect(await surface.getObject(reference: reference) == nil)
        #expect(await surface.getObjectContent(reference: reference) == nil)
        #expect(await surface.listFolder().folders.isEmpty)

        // Even naming the tag directly gives nothing away.
        let tags = await surface.listTags()
        for tag in tags {
            #expect(await surface.findByTag(reference: tag.reference).isEmpty)
        }
    }

    @Test("A locked item can be outlined but never quoted")
    func lockedContentIsDescribedNotQuoted() async throws {
        let (harness, surface) = try await makeLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "salary.txt", contents: "confidential figures")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)
        await harness.service.extractPendingText()
        try await harness.service.setPrivacy(PrivacyFlags(isLocked: true), forObjects: [id])

        let reference = "object://\(id.uuid.uuidString)"
        let digest = try #require(await surface.getObject(reference: reference))
        #expect(digest.isRedacted)
        #expect(digest.title == ObjectSnapshot.lockedPlaceholderTitle)

        let content = try #require(await surface.getObjectContent(reference: reference))
        #expect(content.extractedText == nil)
        #expect(content.unavailableReason == "This item is locked.")
    }

    @Test("Digests carry no filesystem path")
    func digestsExposeNoPaths() async throws {
        let (harness, surface) = try await makeLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "notes.txt", contents: "text")
        await harness.service.importItems([.file(url: source)], into: .root)
        await harness.service.extractPendingText()

        let results = await surface.searchObjects(.init(query: "notes"))
        let encoded = try JSONEncoder().encode(results)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(!json.contains("/Users/"))
        #expect(!json.contains("file://"))
        #expect(!json.contains(harness.scratch.path()))
    }

    @Test("A session with no provider says so rather than failing silently")
    func sessionWithoutProvider() async throws {
        let (harness, surface) = try await makeLibrary()
        defer { harness.cleanUp() }

        let session = IntelligenceSession()
        await #expect(throws: IntelligenceError.self) {
            _ = try await session.respond(
                to: IntelligenceRequest(instruction: "summarise my library"),
                using: surface
            )
        }
    }
}

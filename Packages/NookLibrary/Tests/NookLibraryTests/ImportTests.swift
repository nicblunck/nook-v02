import Foundation
import Testing
@testable import NookLibrary

@Suite("Import")
struct ImportTests {

    @Test("An imported object survives deletion of the file it came from")
    func importDetachesFromSource() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "notes.txt", contents: "hello nook")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)

        try FileManager.default.removeItem(at: source)

        let original = try #require(try await harness.service.originalURL(for: id))
        #expect(try Data(contentsOf: original) == Data("hello nook".utf8))
    }

    @Test("Identical bytes are stored once but produce independent objects")
    func duplicateImportSharesOneBlob() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let first = try harness.makeSourceFile(named: "a.txt", contents: "same bytes")
        let second = try harness.makeSourceFile(named: "b.txt", contents: "same bytes")

        let report = await harness.service.importItems(
            [.file(url: first), .file(url: second)], into: .root
        )

        #expect(report.importedIDs.count == 2)
        #expect(report.duplicateCount == 1)

        let objects = await harness.service.objects(matching: ObjectQuery(scope: .inbox))
        #expect(objects.count == 2)
        // Distinct objects...
        #expect(Set(objects.map(\.id)).count == 2)
        // ...pointing at one stored copy.
        #expect(Set(objects.compactMap { $0.blob?.hash }).count == 1)
    }

    @Test("Import into a folder lands there; import without one lands in the Inbox")
    func importIsContextAware() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "References")
        let inFolder = try harness.makeSourceFile(named: "one.txt", contents: "one")
        let loose = try harness.makeSourceFile(named: "two.txt", contents: "two")

        await harness.service.importItems([.file(url: inFolder)], into: .folder(folder.id))
        await harness.service.importItems([.file(url: loose)], into: .root)

        let folderContents = await harness.service.objects(matching: ObjectQuery(scope: .folder(folder.id)))
        let inbox = await harness.service.objects(matching: ObjectQuery(scope: .inbox))

        #expect(folderContents.map(\.title) == ["one"])
        #expect(inbox.map(\.title) == ["two"])
    }

    @Test("A screenshot is classified apart from an ordinary image")
    func screenshotClassification() {
        #expect(ImportClassifier.isScreenshotName("Screenshot 2026-09-05 at 11.02.13.png"))
        #expect(ImportClassifier.isScreenshotName("CleanShot 2026-09-05.png"))
        #expect(!ImportClassifier.isScreenshotName("sunset-over-kyoto.jpg"))
    }

    @Test("Image dimensions follow their display orientation")
    func imageDimensionsApplyOrientation() {
        #expect(MediaMetadataReader.orientedPixelDimensions(
            width: 4_032, height: 3_024, orientation: 1
        ) == (4_032, 3_024))
        #expect(MediaMetadataReader.orientedPixelDimensions(
            width: 4_032, height: 3_024, orientation: 6
        ) == (3_024, 4_032))
        #expect(MediaMetadataReader.orientedPixelDimensions(
            width: 4_032, height: 3_024, orientation: 8
        ) == (3_024, 4_032))
    }

    @Test("A link is saved as an object with its domain")
    func linkImport() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let url = try #require(URL(string: "https://example.com/articles/typography"))
        let id = try await harness.service.importLink(
            url, into: .root, metadata: LinkMetadata(title: "On Typography")
        )

        let object = try #require(await harness.service.object(id))
        #expect(object.kind == .link)
        #expect(object.title == "On Typography")
        #expect(object.sourceDomain == "example.com")
    }
}

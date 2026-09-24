import Foundation
import Testing
@testable import NookLibrary

@Suite("Export naming")
struct ExportNamingTests {

    private func imported(_ filename: String,
                          renamedTo title: String? = nil) async throws -> (ObjectSnapshot, URL, TestLibrary) {
        let harness = try await TestLibrary()
        let source = try harness.makeSourceFile(named: filename, contents: "bytes of \(filename)")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)
        if let title {
            try await harness.service.updateObject(id, title: title)
        }
        let object = try #require(await harness.service.object(id))
        let stored = try #require(try await harness.service.originalURL(for: id))
        return (object, stored, harness)
    }

    @Test("An object nobody renamed leaves under the filename it came in with")
    func untouchedKeepsOriginalFilename() async throws {
        let (object, stored, harness) = try await imported("IMG_2041-final.jpeg")
        defer { harness.cleanUp() }

        #expect(object.title != "IMG_2041-final")
        #expect(object.exportFilename(storedAs: stored) == "IMG_2041-final.jpeg")
    }

    @Test("A renamed object leaves under its new name with the original's extension")
    func renamedUsesTitle() async throws {
        let (object, stored, harness) = try await imported("IMG_2041.jpeg", renamedTo: "Beach at dusk")
        defer { harness.cleanUp() }

        #expect(object.exportFilename(storedAs: stored) == "Beach at dusk.jpeg")
    }

    @Test("A name that already ends in the extension isn't given it twice")
    func noDoubledExtension() async throws {
        let (object, stored, harness) = try await imported("scan.pdf", renamedTo: "Lease.PDF")
        defer { harness.cleanUp() }

        #expect(object.exportFilename(storedAs: stored) == "Lease.PDF")
    }

    @Test("Separators and a leading dot can't turn a name into a path or hide it")
    func unsafeCharactersAreReplaced() async throws {
        let (object, stored, harness) = try await imported("notes.txt", renamedTo: ".plan 1/2: draft")
        defer { harness.cleanUp() }

        #expect(object.exportFilename(storedAs: stored) == "plan 1-2- draft.txt")
    }
}

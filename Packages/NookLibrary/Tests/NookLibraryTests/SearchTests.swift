import Foundation
import Testing
@testable import NookLibrary

@Suite("Search")
struct SearchTests {

    private func makeLibrary() async throws -> (TestLibrary, FolderID, ObjectID) {
        let harness = try await TestLibrary()
        let folder = try await harness.service.createFolder(named: "Japanese Architecture")
        let source = try harness.makeSourceFile(named: "tadao-ando.txt", contents: "concrete")
        let report = await harness.service.importItems([.file(url: source)], into: .folder(folder.id))
        let id = try #require(report.importedIDs.first)
        try await harness.service.updateObject(id, notes: "Church of the Light")
        try await harness.service.addTag(named: "brutalism", to: [id])
        return (harness, folder.id, id)
    }

    @Test("Search reaches title, notes, tags and containing folder")
    func searchSpansMetadata() async throws {
        let (harness, _, id) = try await makeLibrary()
        defer { harness.cleanUp() }

        for term in ["tadao", "Church of the Light", "brutalism", "Japanese"] {
            let results = await harness.service.objects(matching: ObjectQuery(searchText: term))
            #expect(results.map(\.id) == [id], "expected a hit for \(term)")
        }
    }

    @Test("All terms must match, not just one")
    func searchIsConjunctive() async throws {
        let (harness, _, _) = try await makeLibrary()
        defer { harness.cleanUp() }

        #expect(await harness.service.objects(matching: ObjectQuery(searchText: "tadao brutalism")).count == 1)
        #expect(await harness.service.objects(matching: ObjectQuery(searchText: "tadao helvetica")).isEmpty)
    }

    @Test("Scoping to a folder narrows the same query; removing the scope widens it")
    func scopedSearch() async throws {
        let (harness, folderID, _) = try await makeLibrary()
        defer { harness.cleanUp() }

        // Matches on notes inside the folder, and on the title outside it.
        let elsewhere = try harness.makeSourceFile(named: "light-studies.txt", contents: "unrelated")
        await harness.service.importItems([.file(url: elsewhere)], into: .root)

        let scoped = await harness.service.objects(
            matching: ObjectQuery(scope: .folder(folderID), searchText: "light")
        )
        let global = await harness.service.objects(matching: ObjectQuery(searchText: "light"))

        #expect(scoped.count == 1)
        #expect(global.count == 2)
    }

    @Test("A media-type view is a filter over the same store")
    func mediaTypeScope() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let file = try harness.makeSourceFile(named: "note.txt", contents: "text")
        await harness.service.importItems([.file(url: file)], into: .root)
        _ = try await harness.service.importLink(
            #require(URL(string: "https://example.com")), into: .root
        )

        #expect(await harness.service.objects(matching: ObjectQuery(scope: .kind(.link))).count == 1)
        #expect(await harness.service.objects(matching: ObjectQuery(scope: .kind(.file))).count == 1)
        #expect(await harness.service.objects(matching: ObjectQuery(scope: .allObjects)).count == 2)
    }

    @Test("A reference survives a rename and resolves to the same object")
    func referencesAreDurable() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeSourceFile(named: "original.txt", contents: "bytes")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)

        let reference = try #require(LibraryReference("object://\(id.uuid.uuidString)"))
        try await harness.service.updateObject(id, title: "Renamed Entirely")

        let resolved = await harness.service.resolve(reference)
        guard case .object(let snapshot) = try #require(resolved) else {
            Issue.record("expected an object")
            return
        }
        #expect(snapshot.id == id)
        #expect(snapshot.title == "Renamed Entirely")
    }
}

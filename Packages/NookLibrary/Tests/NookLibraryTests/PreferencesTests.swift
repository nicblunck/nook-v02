import Foundation
import Testing
@testable import NookLibrary

@Suite("View preferences")
struct PreferencesTests {

    @Test("A location has no opinion until it is explicitly asked to remember one")
    func locationsStartWithoutPreferences() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "References")
        #expect(await harness.service.rememberedPreferences(for: .folder(folder.id)) == nil)
    }

    @Test("Remembering stores the whole arrangement; forgetting drops it")
    func rememberAndForget() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "Screenshots")
        let preferences = LocationViewPreferences(
            viewMode: .masonry,
            sort: ObjectSort(field: .name, ascending: true),
            foldersFirst: false,
            masonryCaptionDisplay: .always,
            showsMasonryTypeLabels: false
        )

        try await harness.service.rememberPreferences(preferences, for: .folder(folder.id))
        #expect(await harness.service.rememberedPreferences(for: .folder(folder.id)) == preferences)

        try await harness.service.forgetPreferences(for: .folder(folder.id))
        #expect(await harness.service.rememberedPreferences(for: .folder(folder.id)) == nil)
    }

    @Test("Collections can remember an arrangement too")
    func collectionsRemember() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let collection = try await harness.service.createCollection(named: "Mood")
        let preferences = LocationViewPreferences(
            viewMode: .list, sort: ObjectSort(field: .name, ascending: true), foldersFirst: true
        )
        try await harness.service.rememberPreferences(preferences, for: .collection(collection.id))
        #expect(await harness.service.rememberedPreferences(for: .collection(collection.id)) == preferences)
    }

    @Test("An arrangement saved before item size existed still opens")
    func decodingToleratesAMissingSetting() throws {
        // Exactly what was written before the size setting was added.
        let stored = Data(#"{"viewMode":"masonry","sort":{"field":"name","ascending":true},"foldersFirst":false}"#.utf8)

        let decoded = try JSONDecoder().decode(LocationViewPreferences.self, from: stored)

        #expect(decoded.viewMode == .masonry)
        #expect(decoded.foldersFirst == false)
        #expect(decoded.masonryCaptionDisplay == .automatic)
        #expect(decoded.showsMasonryTypeLabels)
        #expect(decoded.itemScale == LocationViewPreferences.systemDefault.itemScale)
    }

    @Test("An item size out of range is brought back into it")
    func itemScaleIsClamped() {
        #expect(LocationViewPreferences(itemScale: 12).itemScale == LocationViewPreferences.itemScaleRange.upperBound)
        #expect(LocationViewPreferences(itemScale: 0).itemScale == LocationViewPreferences.itemScaleRange.lowerBound)
    }

    @Test("System destinations always follow the global default")
    func systemScopesCannotRemember() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        for scope: LibraryScope in [.inbox, .recent, .favorites, .allObjects, .recentlyDeleted, .kind(.image)] {
            #expect(await harness.service.canRememberPreferences(for: scope) == false)
            // Asking anyway is a no-op rather than an error.
            try await harness.service.rememberPreferences(.systemDefault, for: scope)
            #expect(await harness.service.rememberedPreferences(for: scope) == nil)
        }
    }
}

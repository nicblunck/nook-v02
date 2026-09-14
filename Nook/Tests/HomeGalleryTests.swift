import Foundation
import Testing
import NookLibrary
@testable import Nook

/// The top-level All destination is the app's home surface. It uses the regular
/// object canvas and the all-objects query rather than maintaining a second
/// Home-specific gallery.
@Suite("All")
@MainActor
struct HomeGalleryTests {

    @Test("All shows every object and each root folder")
    func showsAllObjectsAndRootFolders() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Papers", in: nil)
        let folder = try #require(
            model.allFolders.first { $0.folder.name == "Papers" }?.folder.id
        )
        await model.createFolder(named: "Drafts", in: folder)

        model.navigate(to: .scope(.folder(folder)))
        try await harness.importFile(named: "filed.txt", contents: "filed")
        model.navigate(to: .home)
        try await harness.importFile(named: "loose.txt", contents: "loose")
        await model.refreshContents()

        #expect(Set(model.contents.objects.map(\.originalFilename)) == [
            "filed.txt", "loose.txt"
        ])
        #expect(model.contents.folders.map(\.id) == [folder])
        #expect(model.canvasItems.contains {
            if case .folder(let visibleFolder) = $0 {
                return visibleFolder.id == folder
            }
            return false
        })
    }

    @Test("All searches across the whole library")
    func searchesAllObjects() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .home)
        try await harness.importFile(named: "article.txt", contents: "article")
        try await harness.importFile(named: "notes.txt", contents: "notes")
        model.searchText = "article"
        await model.refreshContents()

        #expect(model.contents.objects.map(\.originalFilename) == ["article.txt"])
    }

    @Test("All uses regular canvas selection and keyboard navigation")
    func usesCanvasNavigation() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .home)
        try await harness.importFile(named: "one.txt", contents: "one")
        await model.refreshContents()
        let object = try #require(model.contents.objects.first)

        #expect(model.moveCursor(.right))
        #expect(model.cursor == .object(object.id))
        #expect(model.canOpenCurrentItem)
    }

    @Test("All keeps the home arrangement preference")
    func remembersItsOwnArrangement() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .home)
        await model.loadPreferences()
        #expect(model.canRememberLocation)

        await model.setRememberingLocation(true)
        await model.setViewMode(.list)
        #expect(model.settings.homePreferences?.viewMode == .list)

        model.navigate(to: .scope(.favorites))
        await model.loadPreferences()
        #expect(model.viewMode == model.settings.defaultPreferences.viewMode)

        model.navigate(to: .home)
        await model.loadPreferences()
        #expect(model.viewMode == .list)
    }

    @Test("View mode follows the user across unremembered locations and refreshes")
    func persistsViewModeAcrossApp() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .home)
        await model.loadPreferences()
        await model.setViewMode(.masonry)

        #expect(model.settings.defaultPreferences.viewMode == .masonry)

        await model.refreshAll()
        #expect(model.viewMode == .masonry)

        model.navigate(to: .scope(.favorites))
        await model.loadPreferences()
        #expect(model.viewMode == .masonry)
    }

    @Test("Masonry display options follow the user across unremembered locations")
    func persistsMasonryDisplayOptionsAcrossApp() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .home)
        await model.loadPreferences()
        await model.setMasonryCaptionDisplay(.hidden)
        await model.setShowsMasonryTypeLabels(false)

        #expect(model.settings.defaultPreferences.masonryCaptionDisplay == .hidden)
        #expect(model.settings.defaultPreferences.showsMasonryTypeLabels == false)

        model.navigate(to: .scope(.favorites))
        await model.loadPreferences()
        #expect(model.masonryCaptionDisplay == .hidden)
        #expect(model.showsMasonryTypeLabels == false)
    }

    @Test("A remembered location keeps its own view mode")
    func rememberedLocationOverridesGlobalViewMode() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .home)
        await model.loadPreferences()
        await model.setViewMode(.list)

        await model.createFolder(named: "Pinned View", in: nil)
        let folder = try #require(
            model.allFolders.first { $0.folder.name == "Pinned View" }?.folder.id
        )
        model.navigate(to: .scope(.folder(folder)))
        await model.loadPreferences()
        await model.setRememberingLocation(true)
        await model.setViewMode(.masonry)

        #expect(model.settings.defaultPreferences.viewMode == .list)

        model.navigate(to: .scope(.favorites))
        await model.loadPreferences()
        #expect(model.viewMode == .list)

        model.navigate(to: .scope(.folder(folder)))
        await model.loadPreferences()
        #expect(model.viewMode == .masonry)
    }
}

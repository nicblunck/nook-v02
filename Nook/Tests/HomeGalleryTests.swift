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

@Suite("Content filters")
@MainActor
struct ContentFilterTests {

    @Test("Broad categories map to the expected stored kinds")
    func categoryMappings() {
        #expect(LibraryContentFilter.allCases == [
            .images, .documents, .audio, .video, .links, .folders
        ])
        #expect(LibraryContentFilter.images.objectKinds == [.image, .screenshot])
        #expect(LibraryContentFilter.documents.objectKinds == [.pdf, .file])
        #expect(LibraryContentFilter.audio.objectKinds == [.audio])
        #expect(LibraryContentFilter.video.objectKinds == [.video])
        #expect(LibraryContentFilter.links.objectKinds == [.link])
        #expect(LibraryContentFilter.folders.objectKinds.isEmpty)
    }

    @Test("Each category filters the current location and toggles back to all content")
    func filtersCurrentLocation() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .home)

        await model.createFolder(named: "Projects", in: nil)
        try await harness.importFile(named: "photo.png", contents: "photo", as: .png)
        try await harness.importFile(named: "Screenshot 2026-09-15.png", contents: "shot", as: .png)
        try await harness.importFile(named: "report.pdf", contents: "pdf", as: .pdf)
        try await harness.importFile(named: "notes.txt", contents: "notes", as: .plainText)
        try await harness.importFile(named: "voice.m4a", contents: "audio", as: .audio)
        try await harness.importFile(named: "clip.mov", contents: "video", as: .movie)
        _ = try await model.library.service.importLink(
            #require(URL(string: "https://example.com/reference")), into: .root
        )
        await model.refreshAll()

        await model.toggleContentFilter(.images)
        #expect(Set(model.contents.objects.map(\.kind)) == [.image, .screenshot])
        #expect(model.contents.folders.isEmpty)

        await model.toggleContentFilter(.documents)
        #expect(Set(model.contents.objects.map(\.kind)) == [.pdf, .file])

        await model.toggleContentFilter(.audio)
        #expect(model.contents.objects.map(\.kind) == [.audio])

        await model.toggleContentFilter(.video)
        #expect(model.contents.objects.map(\.kind) == [.video])

        await model.toggleContentFilter(.links)
        #expect(model.contents.objects.map(\.kind) == [.link])

        await model.toggleContentFilter(.folders)
        #expect(model.contents.objects.isEmpty)
        #expect(model.contents.folders.map(\.name) == ["Projects"])

        await model.toggleContentFilter(.folders)
        #expect(model.contentFilter == nil)
        #expect(Set(model.contents.objects.map(\.kind)) == [
            .image, .screenshot, .pdf, .file, .audio, .video, .link
        ])
        #expect(model.contents.folders.map(\.name) == ["Projects"])
    }

    @Test("Filtering preserves navigation and prunes invisible selection")
    func preservesNavigationAndPrunesSelection() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .home)

        let file = try #require(try await harness.importFile(named: "selected.txt"))
        try await harness.importFile(named: "visible.png", contents: "image", as: .png)
        model.selection = [file.id]
        model.cursor = .object(file.id)
        let destination = model.destination
        let couldGoBack = model.canGoBack
        let couldGoForward = model.canGoForward

        await model.toggleContentFilter(.images)

        #expect(model.destination == destination)
        #expect(model.canGoBack == couldGoBack)
        #expect(model.canGoForward == couldGoForward)
        #expect(model.selection.isEmpty)
        #expect(model.cursor == nil)

        model.navigate(to: .scope(.inbox))
        #expect(model.contentFilter == .images)
    }

    @Test("Search combines with object and folder filters")
    func combinesWithSearch() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.navigate(to: .home)

        try await harness.importFile(named: "example.txt", contents: "file")
        _ = try await model.library.service.importLink(
            #require(URL(string: "https://example.com/article")), into: .root
        )
        await model.createFolder(named: "Café Research", in: nil)
        await model.createFolder(named: "Archive", in: nil)
        await model.refreshAll()

        await model.toggleContentFilter(.links)
        model.searchText = "example"
        await model.refreshContents()
        #expect(model.contents.objects.map(\.kind) == [.link])

        model.searchText = ""
        await model.toggleContentFilter(.folders)
        model.searchText = "cafe research"
        await model.refreshContents()
        #expect(model.contents.objects.isEmpty)
        #expect(model.contents.folders.map(\.name) == ["Café Research"])
    }
}

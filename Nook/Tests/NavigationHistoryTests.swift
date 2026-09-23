import Foundation
import Testing
import NookLibrary
@testable import Nook

@MainActor
@Suite("Navigation history")
struct NavigationHistoryTests {

    @Test("Back retraces the path taken and Forward walks it again")
    func retracesThePath() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.destination == .home)
        #expect(!model.canGoBack)

        model.navigate(to: .scope(.inbox))
        model.navigate(to: .scope(.favorites))

        model.goBack()
        #expect(model.destination == .scope(.inbox))
        model.goBack()
        #expect(model.destination == .home)
        #expect(!model.canGoBack)

        model.goForward()
        #expect(model.destination == .scope(.inbox))
        model.goForward()
        #expect(model.destination == .scope(.favorites))
        #expect(!model.canGoForward)
    }

    /// Leaving Home for a scope changes both `isShowingHome` and `scope`. The
    /// user took one step, so Back has to undo one step.
    @Test("Leaving Home records one stop, not two")
    func leavingHomeIsOneStep() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .scope(.favorites))
        model.goBack()

        #expect(model.destination == .home)
        #expect(!model.canGoBack)
    }

    @Test("Opening a folder on the canvas is a step of its own")
    func canvasNavigationIsRecorded() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Papers", in: nil)
        let papers = try #require(model.folderTree.first?.folder)

        model.navigate(to: .scope(.inbox))
        // The canvas sets the scope directly rather than calling `navigate`.
        model.scope = .folder(papers.id)

        model.goBack()
        #expect(model.destination == .scope(.inbox))
    }

    @Test("A new step drops whatever was ahead")
    func newStepClearsForward() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .scope(.inbox))
        model.navigate(to: .scope(.favorites))
        model.goBack()
        #expect(model.canGoForward)

        model.navigate(to: .scope(.allObjects))
        #expect(!model.canGoForward)
    }

    /// Preview replaces the canvas rather than sitting beside it, so the first
    /// step back is out of preview and the place underneath is left alone.
    @Test("Back leaves preview before it leaves the place")
    func backLeavesPreviewFirst() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.navigate(to: .scope(.inbox))
        let object = try #require(try await harness.importFile(named: "note.txt"))
        model.previewedObjectID = object.id

        #expect(model.canGoBack)
        model.goBack()
        #expect(model.previewedObjectID == nil)
        #expect(model.destination == .scope(.inbox))

        model.goBack()
        #expect(model.destination == .home)
    }

    @Test("Reopening the current destination leaves preview")
    func reopeningCurrentDestinationLeavesPreview() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        let object = try #require(try await harness.importFile(named: "note.txt"))
        model.previewedObjectID = object.id

        model.navigate(to: .home)

        #expect(model.previewedObjectID == nil)
        #expect(model.destination == .home)
        #expect(!model.canGoBack)
    }

    @Test("A deleted folder is taken out of the history")
    func deletedFoldersAreForgotten() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Scratch", in: nil)
        let scratch = try #require(model.folderTree.first?.folder)

        model.navigate(to: .scope(.folder(scratch.id)))
        model.navigate(to: .scope(.favorites))
        await model.deleteFolder(scratch.id)

        model.goBack()
        #expect(model.destination != .scope(.folder(scratch.id)))
        #expect(model.destination == .home)
    }

    @Test("Deleting a folder takes its subfolders out of the history too")
    func deletedSubfoldersAreForgotten() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Parent", in: nil)
        let parent = try #require(model.folderTree.first?.folder)
        await model.createFolder(named: "Child", in: parent.id)
        let child = try #require(model.folderTree.first?.children.first?.folder)

        model.navigate(to: .scope(.folder(child.id)))
        model.navigate(to: .scope(.favorites))
        await model.deleteFolder(parent.id)

        model.goBack()
        #expect(model.destination != .scope(.folder(child.id)))
    }

    // MARK: Pages

    private func destinations(_ model: LibraryModel) -> [LibraryDestination] {
        model.pages.map(\.destination)
    }

    /// A step deeper puts its page up once the place has loaded.
    private func go(_ model: LibraryModel, to destination: LibraryDestination) async {
        model.navigate(to: destination)
        await model.refreshContents()
    }

    @Test("Each step is a page, and popping one steps back once")
    func eachStepIsAPage() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.startPagesIfNeeded()
        await go(model, to: .scope(.inbox))
        await go(model, to: .scope(.favorites))
        #expect(destinations(model) == [.home, .scope(.inbox), .scope(.favorites)])

        // The edge swipe off Favorites.
        model.popPages(to: Array(model.pages.prefix(2)))
        #expect(model.destination == .scope(.inbox))
        #expect(model.canGoForward)

        // Back from the keyboard goes the same way.
        model.goBack()
        #expect(model.destination == .home)
        #expect(destinations(model) == [.home])
        #expect(!model.canGoBack)
    }

    @Test("Opening a folder on the canvas pushes a page")
    func canvasFolderIsAPage() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Papers", in: nil)
        let papers = try #require(model.folderTree.first?.folder)

        model.startPagesIfNeeded()
        await model.openFolder(papers.id)
        await model.refreshContents()
        #expect(destinations(model) == [.home, .scope(.folder(papers.id))])

        // Setting the scope directly is a step too.
        model.scope = .inbox
        await model.refreshContents()
        #expect(destinations(model) == [.home, .scope(.folder(papers.id)), .scope(.inbox)])
    }

    @Test("A preview is a page on top, and swiping it away closes the preview")
    func previewIsAPage() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.startPagesIfNeeded()
        await go(model, to: .scope(.inbox))
        let first = ObjectID(), second = ObjectID()
        model.previewedObjectID = first
        #expect(model.pages.count == 3)
        #expect(model.pages.last?.previewedObjectID == first)
        let previewPage = try #require(model.pages.last)
        // The canvas beneath stays live while the preview is up.
        #expect(model.livePageID == model.pages[1].id)

        // Stepping to the next item keeps the same page.
        model.previewedObjectID = second
        #expect(model.pages.count == 3)
        #expect(model.pages.last?.id == previewPage.id)
        #expect(model.pages.last?.previewedObjectID == second)

        model.popPages(to: Array(model.pages.prefix(2)))
        #expect(model.previewedObjectID == nil)
        #expect(model.destination == .scope(.inbox))
        // Leaving a preview is not a change of place.
        #expect(!model.canGoForward)
    }

    @Test("Closing a preview any other way takes its page with it")
    func closingPreviewPopsItsPage() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.startPagesIfNeeded()
        model.previewedObjectID = ObjectID()
        model.goBack()
        #expect(model.pages.count == 1)
        #expect(model.pages.last?.previewedObjectID == nil)
    }

    @Test("Going somewhere from a preview replaces the preview's page")
    func navigatingFromPreview() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.startPagesIfNeeded()
        await go(model, to: .scope(.inbox))
        model.previewedObjectID = ObjectID()
        await go(model, to: .scope(.favorites))
        #expect(destinations(model) == [.home, .scope(.inbox), .scope(.favorites)])
        #expect(model.pages.allSatisfy { $0.previewedObjectID == nil })
    }

    @Test("A place picked in the sidebar starts the stack over")
    func sidebarRestartsTheStack() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.startPagesIfNeeded()
        model.navigate(to: .scope(.inbox))
        model.navigate(to: .scope(.favorites))
        model.navigate(to: .scope(.recent), startingPageStack: true)
        #expect(destinations(model) == [.scope(.recent)])

        // Picking the place already showing still starts over.
        model.navigate(to: .scope(.inbox))
        model.navigate(to: .scope(.inbox), startingPageStack: true)
        #expect(destinations(model) == [.scope(.inbox)])
    }

    @Test("A row in the iPhone list is one page, and Home pops back to the list")
    func listRowIsOnePage() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.beginPages(with: LibraryPage(destination: .scope(.inbox)))
        model.navigate(to: .scope(.inbox))
        #expect(destinations(model) == [.scope(.inbox)])

        model.navigate(to: .scope(.favorites))
        model.popPages(to: [])
        #expect(model.pages.isEmpty)
        // Nothing pushes while the list is showing.
        model.navigate(to: .scope(.recent))
        #expect(model.pages.isEmpty)
    }

    @Test("The app opens on All over the Library list, once")
    func opensOnAll() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        #expect(model.settings.startPage == .all)
        await model.showStartPageAtLaunch()?.value
        #expect(destinations(model) == [.home])
        #expect(model.destination == .home)

        model.popPages(to: [])
        #expect(model.showStartPageAtLaunch() == nil)
        #expect(model.pages.isEmpty)
    }

    @Test("The Library list as start page pushes nothing, and Home pops to it")
    func libraryStartPage() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.settings.startPage = .library

        #expect(model.showStartPageAtLaunch() == nil)
        #expect(model.pages.isEmpty)

        model.beginPages(with: LibraryPage(destination: .scope(.inbox)))
        await model.openPage(.scope(.inbox))
        model.navigate(to: .scope(.favorites))
        model.showStartPage()
        #expect(model.pages.isEmpty)
    }

    @Test("Home pops back to the start page when it is beneath")
    func homePopsToStartPage() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.settings.startPage = .inbox

        await model.showStartPageAtLaunch()?.value
        await go(model, to: .scope(.favorites))
        await go(model, to: .scope(.recent))
        #expect(model.showStartPage() == nil)
        #expect(destinations(model) == [.scope(.inbox)])
        #expect(model.destination == .scope(.inbox))
    }

    @Test("Home from somewhere the start page is not beneath starts the stack over there")
    func homeRestartsAtStartPage() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model
        model.settings.startPage = .favorites

        model.beginPages(with: LibraryPage(destination: .scope(.inbox)))
        await model.openPage(.scope(.inbox))
        model.navigate(to: .scope(.recent))
        await model.showStartPage()?.value
        #expect(destinations(model) == [.scope(.favorites)])
        #expect(model.destination == .scope(.favorites))
    }

    @Test("A folder can be the start page, and a deleted one falls back to All")
    func folderStartPage() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Projects", in: nil)
        let projects = try #require(model.folderTree.first?.folder)
        model.settings.startPage = .folder(projects.id)
        #expect(model.startDestination == .scope(.folder(projects.id)))

        await model.showStartPageAtLaunch()?.value
        #expect(destinations(model) == [.scope(.folder(projects.id))])
        #expect(model.destination == .scope(.folder(projects.id)))

        await model.deleteFolder(projects.id)
        #expect(model.startDestination == .home)
    }

    @Test("The start page is remembered")
    func startPagePersists() {
        let suite = "nook.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let id = FolderID()
        AppSettings(defaults: UserDefaults(suiteName: suite)!).startPage = .folder(id)
        #expect(AppSettings(defaults: UserDefaults(suiteName: suite)!).startPage == .folder(id))
        AppSettings(defaults: UserDefaults(suiteName: suite)!).startPage = .library
        #expect(AppSettings(defaults: UserDefaults(suiteName: suite)!).startPage == .library)
    }

    @Test("A deleted folder's page is taken out of the stack")
    func deletedFolderPageIsPruned() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Scratch", in: nil)
        let scratch = try #require(model.folderTree.first?.folder)

        model.startPagesIfNeeded()
        model.navigate(to: .scope(.folder(scratch.id)))
        model.navigate(to: .scope(.favorites))
        await model.deleteFolder(scratch.id)

        #expect(!destinations(model).contains(.scope(.folder(scratch.id))))
        #expect(model.pages.last?.destination == .scope(.favorites))
    }

    @Test("Going back puts the page's contents straight back rather than loading them again")
    func goingBackRestoresContents() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        await model.createFolder(named: "Papers", in: nil)
        let papers = try #require(model.folderTree.first?.folder)

        model.startPagesIfNeeded()
        await model.refreshContents()
        let home = model.contents
        #expect(home.folders.map(\.id) == [papers.id])

        await model.openFolder(papers.id)
        await model.refreshContents()
        #expect(model.contentsDestination == .scope(.folder(papers.id)))

        model.popPages(to: Array(model.pages.prefix(1)))
        // Before any refresh has had a chance to run.
        #expect(model.contentsDestination == .home)
        #expect(model.contents == home)
    }

    @Test("A step deeper waits for its place to load before its page goes up")
    func pushWaitsForContents() async throws {
        let harness = try await TestModel()
        defer { harness.cleanUp() }
        let model = harness.model

        model.startPagesIfNeeded()
        await model.refreshContents()
        model.navigate(to: .scope(.inbox))
        #expect(destinations(model) == [.home])
        await model.refreshContents()
        #expect(destinations(model) == [.home, .scope(.inbox)])

        // Going back before it arrived undoes a step that never got a page.
        model.navigate(to: .scope(.favorites))
        model.goBack()
        #expect(destinations(model) == [.home, .scope(.inbox)])
        #expect(model.destination == .scope(.inbox))
        await model.refreshContents()
        #expect(destinations(model) == [.home, .scope(.inbox)])
    }
}


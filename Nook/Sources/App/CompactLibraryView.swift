import SwiftUI
import NookLibrary

#if os(iOS)
/// iPhone navigation.
///
/// The same information architecture as the sidebar, reached the way iOS
/// reaches things — a single list of destinations, pushed into rather than
/// switched between with tabs. All, Inbox, Recent and Favorites sit alongside
/// the folder hierarchy, collections, media types and tags, exactly as they
/// do in the sidebar. The app opens on the start page chosen in Settings,
/// pushed over this list — All unless asked otherwise.
/// Adding content moves from a hidden long-press menu to a bottom toolbar
/// that stays docked beneath whatever is pushed on screen.
struct CompactLibraryView: View {
    @Bindable var model: LibraryModel
    @State private var stills = PageStills()

    var body: some View {
        // Every step taken from the list is a page of its own, so the back
        // button and the edge swipe undo one step at a time rather than
        // returning to the list from wherever the canvas has got to.
        NavigationStack(path: path) {
            CompactLibraryList(model: model)
                .navigationDestination(for: LibraryPage.self) { page in
                    LibraryPageView(model: model, page: page)
                }
        }
        .libraryPageStills(stills, model: model)
        .onAppear { model.showStartPageAtLaunch() }
        // Metadata comes up as a sheet here rather than as a side panel.
        .sheet(isPresented: $model.isInspectorPresented) {
            NavigationStack {
                InfoPanel(model: model)
                    .navigationTitle("Info")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.setInspector(false) }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var path: Binding<[LibraryPage]> {
        Binding(
            get: { model.pages },
            set: { requested in
                if requested.count < model.pages.count {
                    model.popPages(to: requested)
                } else if model.pages.isEmpty, let page = requested.last {
                    // A row in the list. The page goes up at once and the
                    // canvas catches up with it.
                    model.beginPages(with: page)
                    Task { await model.openPage(page.destination) }
                }
            }
        )
    }
}

/// Every way to bring content in that's worth a thumb's reach, laid out
/// where a long-press used to hide most of them. One button hides them all
/// behind a menu, rather than several separate icons competing for space in
/// a bottom bar that has no way to tighten their spacing.
///
/// A menu rather than the popover the Mac uses: a popover from a bar item
/// lets taps on the bar pass through instead of dismissing it, and SwiftUI
/// only clears its binding once the exit animation has finished, so the
/// button felt dead for a beat after it closed. A menu dismisses on any tap
/// outside and runs its action after it has gone, so the sheet an item
/// presents never collides with the menu on its way out.
///
/// Shared between the landing list and every scope pushed from it, so the
/// bar reads as one continuous piece of chrome rather than something that
/// comes and goes per screen. `BrowseView` leaves it out while an object is
/// open in detail — there is nothing here to add content to at that point.
struct CompactAddContentToolbar: ToolbarContent {
    let model: LibraryModel
    /// Whether the screen's search field docks between Home and Add. Only a
    /// canvas has anything to search; the landing list leaves it out.
    var includesSearch = false

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        // Adjacent bar items share one glass pill; a spacer between them is
        // what splits Home, the search field and Add into pills of their
        // own, with the field taking whatever width is left over.
        ToolbarItem(placement: .bottomBar) {
            // Pops all the way back to the Library list, whatever the start
            // page is, so the root is always one tap away. A list rather
            // than a house, which would read as the start page. A no-op when
            // already there.
            Button("Library", systemImage: "list.bullet") {
                model.popPages(to: [])
            }
        }
        if includesSearch {
            ToolbarSpacer(.fixed, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
        } else {
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        ToolbarItem(placement: .bottomBar) {
            Menu("Add", systemImage: "plus") {
                Section {
                    item("New Folder…", icon: "ToolbarFolderIcon") {
                        model.editingAppearance = .newFolder(parent: model.currentFolderID)
                    }
                    item("New Collection…", icon: "ToolbarCollectionIcon") {
                        model.editingAppearance = .newCollection(adding: [])
                    }
                    item("New Tag…", icon: "ToolbarTagIcon") {
                        model.editingAppearance = .newTag()
                    }
                }
                Section {
                    item("Add File…", icon: "ToolbarFileIcon") {
                        model.isImporterPresented = true
                    }
                    item("Scan Document…", icon: "ToolbarScanIcon") {
                        model.isDocumentScannerPresented = true
                    }
                    item("Paste", icon: "ToolbarClipboardIcon") {
                        Task { await model.importPasteboard() }
                    }
                    item("Add Photo…", icon: "ToolbarGalleryIcon") {
                        model.isPhotosPickerPresented = true
                    }
                    item("Take Photo…", icon: "ToolbarCameraIcon") {
                        model.isCameraPresented = true
                    }
                }
            }
        }
    }

    private func item(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(uiImage: CompactMenuIcon.image(named: icon))
            }
        }
    }
}

/// The full-colour toolbar assets, redrawn at the size a symbol takes in a
/// menu row. They are single 256px exports with no scale variants, and a
/// menu hands its images to UIKit as they are — SwiftUI's `resizable` and
/// `frame` don't reach it — so left alone each would draw at 256pt.
private enum CompactMenuIcon {
    static let side: CGFloat = 24

    @MainActor private static var cache: [String: UIImage] = [:]

    @MainActor
    static func image(named name: String) -> UIImage {
        if let cached = cache[name] { return cached }
        guard let source = UIImage(named: name) else { return UIImage() }
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        .withRenderingMode(.alwaysOriginal)
        cache[name] = image
        return image
    }
}

/// The library's structure as a pushable list: folders, collections, media
/// types and tags.
struct CompactLibraryList: View {
    @Bindable var model: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
            Section("Library") {
                homeRow(title: "All", symbol: "square.grid.2x2", count: model.counts[.allObjects])
                row(scope: .inbox, title: "Inbox", count: model.counts[.inbox]) {
                    Image(systemName: "tray")
                }
                .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                    let ids = transfers.flatMap(\.ids)
                    guard !ids.isEmpty else { return false }
                    Task { await model.move(ids, to: nil) }
                    return true
                }
                row(scope: .recent, title: "Recent") {
                    Image(systemName: "clock")
                }
                row(scope: .favorites, title: "Favorites", count: model.counts[.favorites]) {
                    Image(systemName: "star")
                }
                .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                    let ids = transfers.flatMap(\.ids)
                    guard !ids.isEmpty else { return false }
                    Task { await model.setFavorite(true, for: ids) }
                    return true
                }
            }

            Section {
                if model.folderTree.isEmpty {
                    Text("No folders yet").foregroundStyle(.tertiary)
                } else {
                    // OutlineGroup handles the nesting; a hand-rolled recursive
                    // row cannot be typed, since its return type would be
                    // defined in terms of itself.
                    OutlineGroup(model.folderTree, children: \.outlineChildren) { node in
                        row(scope: .folder(node.folder.id), title: node.folder.name) {
                            EntityIcon(appearance: node.folder.appearance, fallbackSymbol: "folder")
                        }
                        .draggable(FolderTransfer(id: node.folder.id))
                        .plopIn(trigger: arrivalTrigger(for: node.folder.id),
                                order: arrivalOrder(for: node.folder.id),
                                delay: model.sidebarChange.enterDelay(reduceMotion: reduceMotion))
                        .transition(compactItemTransition)
                        .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                            let ids = transfers.flatMap(\.ids)
                            guard !ids.isEmpty else { return false }
                            Task { await model.move(ids, to: node.folder.id) }
                            return true
                        }
                        .dropDestination(for: FolderTransfer.self) { transfers, _ in
                            guard let moved = transfers.first else { return false }
                            Task { await model.moveFolder(moved.id, to: node.folder.id) }
                            return true
                        }
                    }
                }
            } header: {
                Text("Folders")
                    .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                        let ids = transfers.flatMap(\.ids)
                        guard !ids.isEmpty else { return false }
                        Task { await model.move(ids, to: nil) }
                        return true
                    }
                    .dropDestination(for: FolderTransfer.self) { transfers, _ in
                        guard let moved = transfers.first else { return false }
                        Task { await model.moveFolder(moved.id, to: nil) }
                        return true
                    }
            }

            if !model.collections.isEmpty {
                Section("Collections") {
                    ForEach(model.collections) { collection in
                        row(scope: .collection(collection.id), title: collection.name) {
                            EntityIcon(appearance: collection.appearance, fallbackSymbol: "rectangle.stack")
                        }
                        .plopIn(trigger: arrivalTrigger(for: collection.id),
                                order: arrivalOrder(for: collection.id),
                                delay: model.sidebarChange.enterDelay(reduceMotion: reduceMotion))
                        .transition(compactItemTransition)
                        .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                            let ids = transfers.flatMap(\.ids)
                            guard !ids.isEmpty else { return false }
                            Task { await model.addToCollection(collection.id, objects: ids) }
                            return true
                        }
                    }
                }
                .transition(compactItemTransition)
            }

            if !model.mediaTypes.isEmpty {
                Section("Media Types") {
                    ForEach(model.mediaTypes) { kind in
                        row(scope: .kind(kind), title: kind.pluralDisplayName) {
                            Image(systemName: kind.symbolName)
                        }
                        .transition(compactItemTransition)
                    }
                }
                .transition(compactItemTransition)
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in
                        row(scope: .tag(tag.id), title: tag.name) {
                            EntityIcon(appearance: tag.appearance, fallbackSymbol: "tag")
                        }
                        .transition(compactItemTransition)
                        .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                            let ids = transfers.flatMap(\.ids)
                            guard !ids.isEmpty else { return false }
                            Task { await model.addTag(tag.name, to: ids) }
                            return true
                        }
                    }
                }
                .transition(compactItemTransition)
            }

            Section {
                row(scope: .hidden, title: "Hidden") { Image(systemName: "eye.slash") }
                    .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                        let ids = transfers.flatMap(\.ids)
                        guard !ids.isEmpty else { return false }
                        Task { await model.setHidden(true, for: ids) }
                        return true
                    }
                row(scope: .recentlyDeleted, title: "Recently Deleted", count: model.counts[.recentlyDeleted]) {
                    Image(systemName: "trash")
                }
            }

            Section {
                CloudSyncStatusView(model: model)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .refreshable {
            await model.refreshAll()
        }
        .navigationTitle("Nook")
        // Rows that stay close up behind one that has left, and only once
        // it has gone.
        .animation(model.sidebarChange.shift(reduceMotion: reduceMotion),
                   value: model.sidebarReflowRevision)
        .animation(model.sidebarChange.shift(reduceMotion: reduceMotion),
                   value: model.mediaTypes)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gear") { model.isSettingsPresented = true }
            }
            // `.bottomBar` items are inherited down the navigation stack
            // rather than replaced by a pushed screen's own, so this one
            // declaration is what stays docked beneath every scope pushed
            // from this list — `BrowseView` doesn't redeclare it. Hidden
            // during preview the same way `GalleryToolbar` stands down.
            if model.previewedObjectID == nil {
                CompactAddContentToolbar(model: model)
            }
        }
    }

    /// A place leaving shrinks away; one arriving waits until it has gone
    /// and the rows have closed up, then fades in.
    private var compactItemTransition: AnyTransition {
        model.sidebarChange.itemTransition(
            exit: .scale(scale: 0.94).combined(with: .opacity),
            enter: .scale(scale: 0.94).combined(with: .opacity),
            reduceMotion: reduceMotion
        )
    }

    private func arrivalTrigger(for id: FolderID) -> Int? {
        guard let arrival = model.arrival, arrival.folderOrder(id) != nil else { return nil }
        return arrival.revision
    }

    private func arrivalOrder(for id: FolderID) -> Int {
        model.arrival?.folderOrder(id) ?? 0
    }

    private func arrivalTrigger(for id: CollectionID) -> Int? {
        guard let arrival = model.arrival, arrival.collectionOrder(id) != nil else { return nil }
        return arrival.revision
    }

    private func arrivalOrder(for id: CollectionID) -> Int {
        model.arrival?.collectionOrder(id) ?? 0
    }

    private func row(scope: LibraryScope, title: String, count: Int? = nil,
                     @ViewBuilder icon: () -> some View) -> some View {
        NavigationLink(value: LibraryPage(destination: .scope(scope))) {
            label(title: title, count: count, icon: icon)
        }
    }

    /// "All" is a distinct destination from any scope — it shows the Home
    /// canvas (the Folders First shelf and friends) rather than a plain
    /// query over every object.
    private func homeRow(title: String, symbol: String, count: Int? = nil) -> some View {
        NavigationLink(value: LibraryPage(destination: .home)) {
            label(title: title, count: count) { Image(systemName: symbol) }
        }
    }

    private func label(title: String, count: Int?, @ViewBuilder icon: () -> some View) -> some View {
        Label {
            HStack {
                Text(title)
                if let count, count > 0 {
                    Spacer()
                    Text("\(count)")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                        .motionAware(NookMotion.interaction, value: count)
                }
            }
        } icon: { icon() }
    }
}

#if DEBUG
#Preview {
    PreviewHost { model in
        CompactLibraryView(model: model)
    }
}
#endif
#endif

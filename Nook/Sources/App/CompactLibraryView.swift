import SwiftUI
import NookLibrary

#if os(iOS)
/// iPhone navigation.
///
/// The same information architecture as the sidebar, reached the way iOS
/// reaches things — a single list of destinations, pushed into rather than
/// switched between with tabs. This list itself is the landing page: All,
/// Inbox, Recent and Favorites sit alongside the folder hierarchy,
/// collections, media types and tags, exactly as they do in the sidebar.
/// Adding content moves from a hidden long-press menu to a bottom toolbar
/// that stays docked beneath whatever is pushed on screen.
struct CompactLibraryView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        NavigationStack {
            CompactLibraryList(model: model)
        }
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
}

/// Every way to bring content in that's worth a thumb's reach, laid out
/// where a long-press used to hide most of them. Adding a document also
/// covers scanning one — its own rare enough action to live one tap in
/// rather than take a slot of its own — and organizing (a new folder,
/// collection or tag) sits behind the trailing button the same way.
///
/// Shared between the landing list and every scope pushed from it, so the
/// bar reads as one continuous piece of chrome rather than something that
/// comes and goes per screen. `BrowseView` leaves it out while an object is
/// open in detail — there is nothing here to add content to at that point.
struct CompactAddContentToolbar: ToolbarContent {
    let model: LibraryModel

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        // No `Spacer()` between these: one separates adjacent bottom-bar
        // items into their own floating glass pills, and the point here is
        // one connected group, not five.
        ToolbarItemGroup(placement: .bottomBar) {
            Menu {
                Button("Add File…", systemImage: "doc.badge.plus") {
                    model.isImporterPresented = true
                }
                Button("Scan Document…", systemImage: "doc.viewfinder") {
                    model.isDocumentScannerPresented = true
                }
            } label: {
                Label("Add Document", systemImage: "doc.badge.plus")
            }
            Button("Add Image", systemImage: "photo.badge.plus") {
                model.isPhotosPickerPresented = true
            }
            Button("Take Photo", systemImage: "camera") {
                model.isCameraPresented = true
            }
            Button("Paste", systemImage: "doc.on.clipboard") {
                Task { await model.importPasteboard() }
            }
            Menu {
                Button("New Folder…", systemImage: "folder.badge.plus") {
                    model.editingAppearance = .newFolder(parent: model.currentFolderID)
                }
                Button("New Collection…", systemImage: "rectangle.stack.badge.plus") {
                    model.editingAppearance = .newCollection(adding: [])
                }
                Button("New Tag…", systemImage: "tag") {
                    model.editingAppearance = .newTag()
                }
            } label: {
                Label("New Folder, Collection, or Tag", systemImage: "folder.badge.plus")
            }
        }
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
                        .arriving(trigger: arrivalTrigger(for: node.folder.id),
                                  order: arrivalOrder(for: node.folder.id))
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
                        .arriving(trigger: arrivalTrigger(for: collection.id),
                                  order: arrivalOrder(for: collection.id))
                        .transition(compactItemTransition)
                        .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                            let ids = transfers.flatMap(\.ids)
                            guard !ids.isEmpty else { return false }
                            Task { await model.addToCollection(collection.id, objects: ids) }
                            return true
                        }
                    }
                }
            }

            if !model.mediaTypes.isEmpty {
                Section("Media Types") {
                    ForEach(model.mediaTypes) { kind in
                        row(scope: .kind(kind), title: kind.pluralDisplayName) {
                            Image(systemName: kind.symbolName)
                        }
                    }
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in
                        row(scope: .tag(tag.id), title: tag.name) {
                            EntityIcon(appearance: tag.appearance, fallbackSymbol: "tag")
                        }
                        .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                            let ids = transfers.flatMap(\.ids)
                            guard !ids.isEmpty else { return false }
                            Task { await model.addTag(tag.name, to: ids) }
                            return true
                        }
                    }
                }
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
        .nookMotion(.reflow, value: model.sidebarReflowRevision)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gear") { model.isSettingsPresented = true }
            }
            CompactAddContentToolbar(model: model)
        }
    }

    private var compactItemTransition: AnyTransition {
        .nookDeparture(reduceMotion: reduceMotion)
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
        NavigationLink {
            BrowseView(model: model, showsHistoryControls: false)
                .task { await open(scope) }
        } label: {
            label(title: title, count: count, icon: icon)
        }
    }

    /// "All" is a distinct destination from any scope — it shows the Home
    /// canvas (the Folders First shelf and friends) rather than a plain
    /// query over every object — so it gets its own push rather than going
    /// through `open(_:)`.
    private func homeRow(title: String, symbol: String, count: Int? = nil) -> some View {
        NavigationLink {
            BrowseView(model: model, showsHistoryControls: false)
                .task { await openHome() }
        } label: {
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
                }
            }
        } icon: { icon() }
    }

    private func openHome() async {
        model.navigate(to: .home)
        await model.loadPreferences()
        await model.refreshContents()
    }

    private func open(_ scope: LibraryScope) async {
        guard scope != .hidden else {
            await model.openHidden()
            return
        }
        model.navigate(to: .scope(scope))
        await model.loadPreferences()
        await model.refreshContents()
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

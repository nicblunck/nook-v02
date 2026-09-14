import SwiftUI
import NookLibrary

#if os(iOS)
/// iPhone navigation.
///
/// The same information architecture as the sidebar, reached the way iOS
/// reaches things — tabs and pushes — rather than by shrinking a desktop
/// sidebar into a phone. All, Inbox, the library hierarchy and Search are the
/// primary destinations; everything else lives one level in.
struct CompactLibraryView: View {
    @Bindable var model: LibraryModel

    @State private var tab: CompactTab = .all

    enum CompactTab: Hashable {
        case all, inbox, library, search
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("All", systemImage: "square.grid.2x2", value: CompactTab.all) {
                NavigationStack { BrowseView(model: model) }
            }

            Tab("Inbox", systemImage: "tray", value: CompactTab.inbox) {
                NavigationStack { BrowseView(model: model) }
            }

            Tab("Library", systemImage: "square.grid.2x2", value: CompactTab.library) {
                NavigationStack { CompactLibraryList(model: model) }
            }

            Tab("Search", systemImage: "magnifyingglass", value: CompactTab.search, role: .search) {
                NavigationStack { BrowseView(model: model) }
            }
        }
        // Lets scrolling in any tab's content shrink the tab bar out of the
        // way, the same as Apple's own apps; the accessory rides along,
        // dropping in beside the collapsed bar rather than staying pinned
        // above it at full size.
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: tab != .search) {
            LibraryFloatingActionButton(model: model, fillsAccessory: true)
        }
        .onChange(of: tab) { _, newValue in
            switch newValue {
            case .all:
                model.navigate(to: .home)
            case .inbox:
                model.navigate(to: .scope(.inbox))
            case .search:
                model.navigate(to: .scope(.allObjects))
                model.requestSearchFieldFocus()
            case .library:
                // The Library tab returns to whichever place was last open.
                model.navigate(to: .scope(model.scope))
            }
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

/// The library's structure as a pushable list: folders, collections, media
/// types and tags.
struct CompactLibraryList: View {
    @Bindable var model: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
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
                        .plopIn(trigger: arrivalTrigger(for: collection.id),
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

            if !model.presentMediaKinds.isEmpty {
                Section("Media Types") {
                    ForEach(ObjectKind.mediaTypes.filter(model.presentMediaKinds.contains)) { kind in
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
                row(scope: .favorites, title: "Favorites") { Image(systemName: "star") }
                    .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                        let ids = transfers.flatMap(\.ids)
                        guard !ids.isEmpty else { return false }
                        Task { await model.setFavorite(true, for: ids) }
                        return true
                    }
            }

            Section {
                Button {
                    Task { await model.toggleHiddenItems() }
                } label: {
                    Label("Show Hidden Items",
                          systemImage: model.isShowingHiddenContent ? "eye" : "eye.slash")
                }
                    .dropDestination(for: ObjectTransfer.self) { transfers, _ in
                        let ids = transfers.flatMap(\.ids)
                        guard !ids.isEmpty else { return false }
                        Task { await model.setHidden(true, for: ids) }
                        return true
                    }
                row(scope: .recentlyDeleted, title: "Recently Deleted") { Image(systemName: "trash") }
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
        .navigationTitle("Library")
        .animation(reduceMotion ? nil : NookMotion.reflow,
                   value: model.sidebarReflowRevision)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
                    Divider()
                    Button("Settings…", systemImage: "gear") { model.isSettingsPresented = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var compactItemTransition: AnyTransition {
        let movement = AnyTransition.scale(scale: 0.94).combined(with: .opacity)
        return .motionAware(movement, reduceMotion: reduceMotion)
            .animation(reduceMotion ? NookMotion.reduced : NookMotion.reflow)
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

    private func row(scope: LibraryScope, title: String, @ViewBuilder icon: () -> some View) -> some View {
        NavigationLink {
            BrowseView(model: model, showsHistoryControls: false)
                .task { await open(scope) }
        } label: {
            Label { Text(title) } icon: { icon() }
        }
    }

    private func open(_ scope: LibraryScope) async {
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

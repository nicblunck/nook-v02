import SwiftUI
import NookLibrary

#if os(iOS)
/// iPhone navigation.
///
/// The same information architecture as the sidebar, reached the way iOS
/// reaches things — tabs and pushes — rather than by shrinking a desktop
/// sidebar into a phone. Home, Inbox, the library hierarchy and Search are the
/// primary destinations; everything else lives one level in.
struct CompactLibraryView: View {
    @Bindable var model: LibraryModel

    @State private var tab: CompactTab = .home

    enum CompactTab: Hashable {
        case home, inbox, library, search
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: CompactTab.home) {
                NavigationStack { HomeView(model: model) }
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
        .onChange(of: tab) { _, newValue in
            switch newValue {
            case .home:
                model.isShowingHome = true
            case .inbox:
                model.isShowingHome = false
                model.scope = .inbox
            case .search:
                model.isShowingHome = false
                model.scope = .allObjects
                model.requestSearchFieldFocus()
            case .library:
                model.isShowingHome = false
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
                            Button("Done") { model.isInspectorPresented = false }
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

    var body: some View {
        List {
            Section("Folders") {
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
                    }
                }
            }

            if !model.collections.isEmpty {
                Section("Collections") {
                    ForEach(model.collections) { collection in
                        row(scope: .collection(collection.id), title: collection.name) {
                            EntityIcon(appearance: collection.appearance, fallbackSymbol: "rectangle.stack")
                        }
                    }
                }
            }

            Section("Media Types") {
                ForEach(ObjectKind.mediaTypes) { kind in
                    row(scope: .kind(kind), title: kind.pluralDisplayName) {
                        Image(systemName: kind.symbolName)
                    }
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in
                        row(scope: .tag(tag.id), title: tag.name) {
                            EntityIcon(appearance: tag.appearance, fallbackSymbol: "tag")
                        }
                    }
                }
            }

            Section {
                row(scope: .favorites, title: "Favorites") { Image(systemName: "star") }
                row(scope: .allObjects, title: "All Objects") { Image(systemName: "square.grid.2x2") }
                row(scope: .recentlyDeleted, title: "Recently Deleted") { Image(systemName: "trash") }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Folder…", systemImage: "folder.badge.plus") {
                        model.namingPrompt = .newFolder(parent: nil)
                    }
                    Button("New Collection…", systemImage: "rectangle.stack.badge.plus") {
                        model.namingPrompt = .newCollection
                    }
                    Divider()
                    Button("Settings…", systemImage: "gear") { model.isSettingsPresented = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private func row(scope: LibraryScope, title: String, @ViewBuilder icon: () -> some View) -> some View {
        NavigationLink {
            BrowseView(model: model)
                .task { await open(scope) }
        } label: {
            Label { Text(title) } icon: { icon() }
        }
    }

    private func open(_ scope: LibraryScope) async {
        model.isShowingHome = false
        model.scope = scope
        await model.loadPreferences()
        await model.refreshContents()
    }
}
#endif

import SwiftUI
import NookLibrary

/// The library's navigation surface: system destinations, the true folder
/// hierarchy, collections, media types and tags.
///
/// Objects never appear here — the sidebar names places, not things.
struct SidebarView: View {
    @Bindable var model: LibraryModel

    @State private var namingPrompt: NamingPrompt?
    @State private var draftName = ""
    @State private var editingAppearance: AppearanceTarget?

    var body: some View {
        List(selection: selectionBinding) {
            Section("Library") {
                systemRow(.inbox, title: "Inbox", symbol: "tray", count: model.counts[.inbox])
                systemRow(.recent, title: "Recent", symbol: "clock")
                systemRow(.favorites, title: "Favorites", symbol: "star", count: model.counts[.favorites])
                systemRow(.allObjects, title: "All Objects", symbol: "square.grid.2x2", count: model.counts[.allObjects])
            }

            Section("Folders") {
                if model.folderTree.isEmpty {
                    Text("No folders yet").font(.callout).foregroundStyle(.tertiary)
                } else {
                    OutlineGroup(model.folderTree, children: \.outlineChildren) { node in
                        folderRow(node.folder)
                    }
                }
            }

            Section("Collections") {
                if model.collections.isEmpty {
                    Text("No collections yet").font(.callout).foregroundStyle(.tertiary)
                } else {
                    ForEach(model.collections) { collection in
                        collectionRow(collection)
                    }
                }
            }

            Section("Media Types") {
                ForEach(ObjectKind.mediaTypes) { kind in
                    Label(kind.pluralDisplayName, systemImage: kind.symbolName)
                        .tag(LibraryScope.kind(kind))
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in
                        tagRow(tag)
                    }
                }
            }

            Section {
                systemRow(.recentlyDeleted, title: "Recently Deleted",
                          symbol: "trash", count: model.counts[.recentlyDeleted])
            }
        }
        .navigationTitle("Nook")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Folder…", systemImage: "folder.badge.plus") {
                        prompt(.newFolder(parent: currentFolderID), initial: "")
                    }
                    Button("New Collection…", systemImage: "rectangle.stack.badge.plus") {
                        prompt(.newCollection, initial: "")
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
            }
        }
        .alert(namingPrompt?.title ?? "", isPresented: namingBinding) {
            TextField(namingPrompt?.placeholder ?? "Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button(namingPrompt?.confirmTitle ?? "Save") { commitNaming() }
        } message: {
            if let message = namingPrompt?.message { Text(message) }
        }
        .sheet(item: $editingAppearance) { target in
            AppearanceEditor(title: target.title, appearance: target.appearance) { appearance in
                Task { await model.setAppearance(appearance, for: target.reference) }
            }
        }
    }

    // MARK: Rows

    private func systemRow(_ scope: LibraryScope, title: String, symbol: String, count: Int? = nil) -> some View {
        Label {
            HStack {
                Text(title)
                if let count, count > 0 {
                    Spacer()
                    Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(scope)
    }

    private func folderRow(_ folder: FolderSnapshot) -> some View {
        Label {
            HStack {
                Text(folder.name)
                if folder.isLocked {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } icon: {
            EntityIcon(appearance: folder.appearance, fallbackSymbol: "folder")
        }
        .tag(LibraryScope.folder(folder.id))
        .contextMenu {
            Button("Rename…") { prompt(.renameFolder(folder.id), initial: folder.name) }
            Button("New Subfolder…") { prompt(.newFolder(parent: folder.id), initial: "") }
            Button("Customize…") {
                editingAppearance = AppearanceTarget(
                    reference: .folder(folder.id), title: folder.name, appearance: folder.appearance
                )
            }
            Divider()
            Button("Delete Folder", role: .destructive) {
                Task { await model.deleteFolder(folder.id) }
            }
        }
        // Dropping objects onto a folder moves them: this is the true
        // hierarchy, so the drop is a real relocation.
        .dropDestination(for: ObjectTransfer.self) { transfers, _ in
            Task { await model.move(transfers.map(\.id), to: folder.id) }
            return true
        }
    }

    private func collectionRow(_ collection: CollectionSnapshot) -> some View {
        Label {
            HStack {
                Text(collection.name)
                if collection.memberCount > 0 {
                    Spacer()
                    Text("\(collection.memberCount)").foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        } icon: {
            EntityIcon(appearance: collection.appearance, fallbackSymbol: "rectangle.stack")
        }
        .tag(LibraryScope.collection(collection.id))
        .contextMenu {
            Button("Rename…") { prompt(.renameCollection(collection.id), initial: collection.name) }
            Button("Customize…") {
                editingAppearance = AppearanceTarget(
                    reference: .collection(collection.id),
                    title: collection.name,
                    appearance: collection.appearance
                )
            }
            Divider()
            Button("Delete Collection", role: .destructive) {
                Task { await model.deleteCollection(collection.id) }
            }
        }
        // A drop here adds a membership. Nothing moves.
        .dropDestination(for: ObjectTransfer.self) { transfers, _ in
            Task { await model.addToCollection(collection.id, objects: transfers.map(\.id)) }
            return true
        }
    }

    private func tagRow(_ tag: TagSnapshot) -> some View {
        Label {
            HStack {
                Text(tag.name)
                Spacer()
                Text("\(tag.objectCount)").foregroundStyle(.tertiary).monospacedDigit()
            }
        } icon: {
            EntityIcon(appearance: tag.appearance, fallbackSymbol: "tag")
        }
        .tag(LibraryScope.tag(tag.id))
        .contextMenu {
            Button("Rename…") { prompt(.renameTag(tag.id), initial: tag.name) }
            Button("Customize…") {
                editingAppearance = AppearanceTarget(
                    reference: .tag(tag.id), title: tag.name, appearance: tag.appearance
                )
            }
            Divider()
            Button("Delete Tag", role: .destructive) {
                Task { await model.deleteTag(tag.id) }
            }
        }
        .dropDestination(for: ObjectTransfer.self) { transfers, _ in
            Task { await model.addTag(tag.name, to: transfers.map(\.id)) }
            return true
        }
    }

    // MARK: Naming

    private func prompt(_ kind: NamingPrompt, initial: String) {
        draftName = initial
        namingPrompt = kind
    }

    private func commitNaming() {
        guard let namingPrompt else { return }
        let name = draftName
        Task {
            switch namingPrompt {
            case .newFolder(let parent):
                await model.createFolder(named: name, in: parent)
            case .renameFolder(let id):
                await model.rename(folder: id, to: name)
            case .newCollection:
                await model.createCollection(named: name)
            case .renameCollection(let id):
                await model.renameCollection(id, to: name)
            case .renameTag(let id):
                await model.renameTag(id, to: name)
            }
        }
    }

    private var currentFolderID: FolderID? {
        if case .folder(let id) = model.scope { return id }
        return nil
    }

    // MARK: Bindings

    private var selectionBinding: Binding<LibraryScope?> {
        Binding(get: { model.scope }, set: { if let value = $0 { model.scope = value } })
    }

    private var namingBinding: Binding<Bool> {
        Binding(get: { namingPrompt != nil }, set: { if !$0 { namingPrompt = nil } })
    }
}

/// The rename/create prompts the sidebar can raise.
private enum NamingPrompt: Identifiable {
    case newFolder(parent: FolderID?)
    case renameFolder(FolderID)
    case newCollection
    case renameCollection(CollectionID)
    case renameTag(TagID)

    var id: String {
        switch self {
        case .newFolder(let parent): "newFolder-\(parent?.description ?? "root")"
        case .renameFolder(let id): "renameFolder-\(id)"
        case .newCollection: "newCollection"
        case .renameCollection(let id): "renameCollection-\(id)"
        case .renameTag(let id): "renameTag-\(id)"
        }
    }

    var title: String {
        switch self {
        case .newFolder: "New Folder"
        case .renameFolder: "Rename Folder"
        case .newCollection: "New Collection"
        case .renameCollection: "Rename Collection"
        case .renameTag: "Rename Tag"
        }
    }

    var confirmTitle: String {
        switch self {
        case .newFolder, .newCollection: "Create"
        default: "Rename"
        }
    }

    var placeholder: String { "Name" }

    var message: String? {
        switch self {
        case .newFolder(let parent):
            parent == nil ? "At the top level of your library." : "Inside the selected folder."
        case .newCollection:
            "Collections gather items from anywhere without moving them."
        default:
            nil
        }
    }
}

/// The entity whose appearance is being edited.
struct AppearanceTarget: Identifiable {
    let reference: LibraryReference
    let title: String
    let appearance: EntityAppearance

    var id: UUID { reference.uuid }
}

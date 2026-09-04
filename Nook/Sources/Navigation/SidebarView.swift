import SwiftUI
import NookLibrary

/// The library's navigation surface: system destinations, the true folder
/// hierarchy, collections, media types and tags.
///
/// Objects never appear here — the sidebar names places, not things.
struct SidebarView: View {
    @Bindable var model: LibraryModel
    @State private var renamingFolder: FolderSnapshot?
    @State private var isCreatingFolder = false
    @State private var draftName = ""

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
                    Text("No folders yet")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    OutlineGroup(model.folderTree, children: \.outlineChildren) { node in
                        folderRow(node.folder)
                    }
                }
            }

            if !model.collections.isEmpty {
                Section("Collections") {
                    ForEach(model.collections) { collection in
                        Label {
                            Text(collection.name)
                        } icon: {
                            Image(systemName: collection.appearance.symbolName ?? "rectangle.stack")
                                .foregroundStyle(Color(hex: collection.appearance.colorHex) ?? .accentColor)
                        }
                        .tag(LibraryScope.collection(collection.id))
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
                        Label {
                            Text(tag.name)
                            Spacer()
                            Text("\(tag.objectCount)").foregroundStyle(.tertiary)
                        } icon: {
                            Image(systemName: tag.appearance.symbolName ?? "tag")
                                .foregroundStyle(Color(hex: tag.appearance.colorHex) ?? .secondary)
                        }
                        .tag(LibraryScope.tag(tag.id))
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
                Button("New Folder", systemImage: "folder.badge.plus") {
                    draftName = ""
                    isCreatingFolder = true
                }
            }
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = draftName
                Task { await model.createFolder(named: name) }
            }
        } message: {
            Text(newFolderDestinationDescription)
        }
        .alert("Rename Folder", isPresented: renamingBinding) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let folder = renamingFolder else { return }
                let name = draftName
                Task { await model.rename(folder: folder.id, to: name) }
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
            Image(systemName: folder.appearance.symbolName ?? "folder")
                .foregroundStyle(Color(hex: folder.appearance.colorHex) ?? .accentColor)
        }
        .tag(LibraryScope.folder(folder.id))
        .contextMenu {
            Button("Rename…") {
                draftName = folder.name
                renamingFolder = folder
            }
            Button("New Subfolder…") {
                draftName = ""
                model.scope = .folder(folder.id)
                isCreatingFolder = true
            }
            Divider()
            Button("Delete Folder", role: .destructive) {
                Task { await model.deleteFolder(folder.id) }
            }
        }
        // Dropping objects onto a folder moves them; this is the true
        // hierarchy, so the move is a real relocation.
        .dropDestination(for: ObjectTransfer.self) { transfers, _ in
            Task { await model.move(transfers.map(\.id), to: folder.id) }
            return true
        }
    }

    // MARK: Bindings

    private var selectionBinding: Binding<LibraryScope?> {
        Binding(
            get: { model.scope },
            set: { if let value = $0 { model.scope = value } }
        )
    }

    private var renamingBinding: Binding<Bool> {
        Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )
    }

    private var newFolderDestinationDescription: String {
        if case .folder(let id) = model.scope,
           let parent = model.allFolders.first(where: { $0.folder.id == id })?.folder {
            return "Inside “\(parent.name)”."
        }
        return "At the top level of your library."
    }
}

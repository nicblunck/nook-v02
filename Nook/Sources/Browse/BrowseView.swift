import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

/// The content canvas. Browsing and preview occupy the same space: opening an
/// object replaces the grid rather than stacking a window on top of it.
struct BrowseView: View {
    @Bindable var model: LibraryModel
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            if let previewed = model.previewedObject {
                ObjectPreviewView(model: model, object: previewed)
                    .transition(.opacity)
            } else {
                canvas
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.22), value: model.previewedObjectID)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .searchable(text: $model.searchText, prompt: searchPrompt)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.importFiles(at: urls) }
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        Group {
            if model.contents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: 16)],
                              spacing: 16) {
                        // Folders First: locations lead, then their contents.
                        ForEach(model.contents.folders) { folder in
                            FolderCard(folder: folder) { model.scope = .folder(folder.id) }
                        }
                        ForEach(model.contents.objects) { object in
                            ObjectCard(
                                object: object,
                                isSelected: model.selection.contains(object.id),
                                onOpen: { open(object) },
                                onSelect: { modifiers in select(object, modifiers: modifiers) }
                            )
                            .contextMenu { ObjectMenu(model: model, objects: contextTargets(for: object)) }
                            .draggable(ObjectTransfer(id: object.id))
                        }
                    }
                    .padding(20)
                }
                #if os(macOS)
                .onTapGesture { model.selection = [] }
                #endif
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importFiles(at: urls) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay { if isDropTargeted { dropIndicator } }
    }

    private var dropIndicator: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .padding(8)
            .allowsHitTesting(false)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
        } description: {
            Text(emptyDescription)
        } actions: {
            if !model.searchText.isEmpty {
                Button("Clear Search") { model.searchText = "" }
            } else if model.scope != .recentlyDeleted {
                Button("Import Files…") { isImporterPresented = true }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.previewedObjectID == nil {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: sortFieldBinding) {
                        ForEach(sortFields, id: \.self) { field in
                            Text(field.displayName).tag(field)
                        }
                    }
                    Divider()
                    Picker("Order", selection: sortAscendingBinding) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }

            ToolbarItem {
                Button("Import", systemImage: "plus") { isImporterPresented = true }
            }
        }

        ToolbarItem {
            Button("Info", systemImage: "info.circle") {
                model.isInspectorPresented.toggle()
            }
        }
    }

    private var sortFields: [ObjectSortField] {
        var fields: [ObjectSortField] = [.name, .dateAdded, .dateCreated, .kind, .size]
        if case .collection = model.scope { fields.insert(.manual, at: 0) }
        return fields
    }

    private var sortFieldBinding: Binding<ObjectSortField> {
        Binding(get: { model.sort.field },
                set: { model.sort = ObjectSort(field: $0, ascending: model.sort.ascending) })
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(get: { model.sort.ascending },
                set: { model.sort = ObjectSort(field: model.sort.field, ascending: $0) })
    }

    // MARK: Actions

    private func open(_ object: ObjectSnapshot) {
        // A link is a pointer to the live web, not stored content, so it opens
        // where the user's browsing actually happens.
        if object.kind == .link, let url = object.sourceURL {
            OpenExternally.open(url)
            return
        }
        model.selection = [object.id]
        model.previewedObjectID = object.id
    }

    private func select(_ object: ObjectSnapshot, modifiers: EventModifiers) {
        if modifiers.contains(.command) {
            if model.selection.contains(object.id) {
                model.selection.remove(object.id)
            } else {
                model.selection.insert(object.id)
            }
        } else if modifiers.contains(.shift), let anchor = model.selection.first {
            model.selection.formUnion(range(from: anchor, to: object.id))
        } else {
            model.selection = [object.id]
        }
    }

    private func range(from anchor: ObjectID, to target: ObjectID) -> Set<ObjectID> {
        let ids = model.contents.objects.map(\.id)
        guard let start = ids.firstIndex(of: anchor), let end = ids.firstIndex(of: target) else {
            return [target]
        }
        return Set(ids[min(start, end)...max(start, end)])
    }

    /// Acting on an unselected item should act on that item, not on a stale
    /// selection somewhere else in the grid.
    private func contextTargets(for object: ObjectSnapshot) -> [ObjectSnapshot] {
        model.selection.contains(object.id) ? model.selectedObjects : [object]
    }

    // MARK: Copy

    private var title: String {
        switch model.scope {
        case .folder: model.breadcrumbs.last?.name ?? "Folder"
        case .collection(let id): model.collections.first { $0.id == id }?.name ?? "Collection"
        case .tag(let id): model.tags.first { $0.id == id }?.name ?? "Tag"
        default: model.scope.displayName
        }
    }

    private var searchPrompt: String {
        switch model.scope {
        case .allObjects: "Search your library"
        default: "Search in \(title)"
        }
    }

    private var emptyTitle: String {
        if !model.searchText.isEmpty { return "No Results" }
        switch model.scope {
        case .inbox: return "Inbox Zero"
        case .favorites: return "No Favorites"
        case .recentlyDeleted: return "Nothing Deleted"
        default: return "Nothing Here Yet"
        }
    }

    private var emptySymbol: String {
        if !model.searchText.isEmpty { return "magnifyingglass" }
        switch model.scope {
        case .inbox: return "tray"
        case .favorites: return "star"
        case .recentlyDeleted: return "trash"
        default: return "square.grid.2x2"
        }
    }

    private var emptyDescription: String {
        if !model.searchText.isEmpty {
            return "No items in \(title) match “\(model.searchText)”."
        }
        switch model.scope {
        case .inbox: return "Anything you import without choosing a folder waits here."
        case .favorites: return "Items you favorite show up here."
        case .recentlyDeleted: return "Deleted items stay here for 30 days before they're removed."
        default: return "Drag files in, or import them, to get started."
        }
    }
}

enum OpenExternally {
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

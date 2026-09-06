import SwiftUI
import NookLibrary

/// The library's navigation surface: system destinations, the true folder
/// hierarchy, collections, media types and tags.
///
/// Objects never appear here — the sidebar names places, not things.
struct SidebarView: View {
    @Bindable var model: LibraryModel

    @State private var editingAppearance: AppearanceTarget?
    /// The list itself holds the keyboard, rather than an invisible layer
    /// beside it. That is the whole point: a sidebar list that AppKit knows is
    /// focused paints its own selection — accent while it has the keyboard,
    /// grey when it doesn't, full width, right shape — and recolours the
    /// labels and symbols on it for contrast.
    @FocusState private var isListFocused: Bool

    var body: some View {
        list
        #if os(macOS)
            // Up and down belong to the list, which does them the way every
            // other Mac sidebar does. These are the few keys the sidebar means
            // something particular by, taken before the list can decline them.
            .background(
                WindowKeyMonitor(
                    isActive: model.keyboardPane == .sidebar && model.namingPrompt == nil,
                    onKey: handleKey
                )
            )
        #endif
            .focused($isListFocused)
            .onAppear { syncFocus() }
            .onChange(of: model.keyboardFocusRequest) { syncFocus() }
            // Clicking a row is another way of saying the keyboard belongs
            // here, and clicking the row you are already on changes no
            // selection — so nothing else would say it.
            .onChange(of: isListFocused) { _, focused in
                if focused { model.focus(.sidebar) }
            }
    }

    private var list: some View {
        List(selection: selectionBinding) {
            Section("Library") {
                Label("Home", systemImage: "house")
                    .tag(LibraryDestination.home)
                systemRow(.inbox, title: "Inbox", symbol: "tray", count: model.counts[.inbox])
                systemRow(.recent, title: "Recent", symbol: "clock")
                systemRow(.favorites, title: "Favorites", symbol: "star", count: model.counts[.favorites])
                systemRow(.allObjects, title: "All Objects", symbol: "square.grid.2x2", count: model.counts[.allObjects])
            }

            Section {
                if model.folderTree.isEmpty {
                    Text("No folders yet").font(.callout).foregroundStyle(.tertiary)
                } else {
                    FolderRows(nodes: model.folderTree, model: model) { folder in
                        AnyView(folderRow(folder))
                    }
                }
            } header: {
                Text("Folders")
                    .dropDestination(for: FolderTransfer.self) { transfers, _ in
                        guard let moved = transfers.first else { return false }
                        Task { await model.moveFolder(moved.id, to: nil) }
                        return true
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
                        .tag(LibraryDestination.scope(.kind(kind)))
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags) { tag in
                        tagRow(tag)
                    }
                }
            }

        }
        .navigationTitle("Nook")
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Folder…", systemImage: "folder.badge.plus") {
                        prompt(.newFolder(parent: model.currentFolderID), initial: "")
                    }
                    Button("New Collection…", systemImage: "rectangle.stack.badge.plus") {
                        prompt(.newCollection, initial: "")
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editingAppearance) { target in
            AppearanceEditor(title: target.title, appearance: target.appearance) { appearance in
                Task { await model.setAppearance(appearance, for: target.reference) }
            }
        }
    }

    // MARK: Footer

    /// The two places the library's structure does not lead to: what has been
    /// put out of sight, and what is on its way out. Neither is a folder, a
    /// collection or a tag, so neither belongs in the list above — they sit in
    /// a row of their own at the foot of the sidebar, the way Photos keeps its
    /// album list and its Hidden and Recently Deleted apart.
    private var footer: some View {
        HStack(spacing: 6) {
            footerButton(title: "Hidden",
                         symbol: "eye.slash",
                         isCurrent: model.scope == .hidden) {
                Task { await model.openHidden() }
            }
            // No count here. How much someone is keeping out of sight is
            // itself something they are keeping out of sight.
            footerButton(title: "Recently Deleted",
                         symbol: "trash",
                         isCurrent: model.scope == .recentlyDeleted,
                         count: model.counts[.recentlyDeleted]) {
                model.navigate(to: .scope(.recentlyDeleted))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func footerButton(title: String,
                              symbol: String,
                              isCurrent: Bool,
                              count: Int? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title).lineLimit(1).truncationMode(.tail)
                if let count, count > 0 {
                    Spacer(minLength: 2)
                    Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(isCurrent ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 6))
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(count.flatMap { $0 > 0 ? Format.itemCount($0) : nil } ?? "")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
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
        // Spoken, the trailing number is just a number: "Inbox, 12" could as
        // easily be a name as a tally. The count becomes the row's value.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(count.flatMap { $0 > 0 ? Format.itemCount($0) : nil } ?? "")
        .tag(LibraryDestination.scope(scope))
    }

    private func folderRow(_ folder: FolderSnapshot) -> some View {
        Label {
            HStack {
                Text(folder.name)
                privacyBadges(isHidden: folder.isHidden, isLocked: folder.isLocked)
            }
        } icon: {
            EntityIcon(appearance: folder.appearance, fallbackSymbol: "folder")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(folder.name)
        .accessibilityValue(spokenPrivacy(isHidden: folder.isHidden, isLocked: folder.isLocked)
            .joined(separator: ", "))
        .tag(LibraryDestination.scope(.folder(folder.id)))
        .draggable(FolderTransfer(id: folder.id))
        .contextMenu {
            Button("Rename…") { prompt(.renameFolder(folder.id), initial: folder.name) }
            Button("New Subfolder…") { prompt(.newFolder(parent: folder.id), initial: "") }
            Button("Customize…") {
                editingAppearance = AppearanceTarget(
                    reference: .folder(folder.id), title: folder.name, appearance: folder.appearance
                )
            }
            Divider()
            privacyItems(for: folder,
                         hide: { await model.setHidden($0, forFolder: folder) },
                         lock: { await model.setLocked($0, forFolder: folder) })
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
        .dropDestination(for: FolderTransfer.self) { transfers, _ in
            guard let moved = transfers.first else { return false }
            Task { await model.moveFolder(moved.id, to: folder.id) }
            return true
        }
    }

    private func collectionRow(_ collection: CollectionSnapshot) -> some View {
        Label {
            HStack {
                Text(collection.name)
                privacyBadges(isHidden: collection.isHidden, isLocked: collection.isLocked)
                if collection.memberCount > 0 {
                    Spacer()
                    Text("\(collection.memberCount)").foregroundStyle(.tertiary).monospacedDigit()
                }
            }
        } icon: {
            EntityIcon(appearance: collection.appearance, fallbackSymbol: "rectangle.stack")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(collection.name)
        .accessibilityValue(spokenCollectionState(collection))
        .tag(LibraryDestination.scope(.collection(collection.id)))
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
            // A hidden or locked collection conceals the collection itself.
            // What it gathers stays exactly as reachable as it was: the true
            // folder hierarchy is where storage privacy lives.
            privacyItems(for: collection,
                         hide: { await model.setHidden($0, forCollection: collection) },
                         lock: { await model.setLocked($0, forCollection: collection) })
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tag.name)
        .accessibilityValue(Format.itemCount(tag.objectCount))
        .tag(LibraryDestination.scope(.tag(tag.id)))
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

    // MARK: Privacy

    /// The marks a place carries when it is hidden, locked, or both. Small and
    /// tertiary on purpose: they say what state a place is in, never anything
    /// about what it holds.
    @ViewBuilder
    private func privacyBadges(isHidden: Bool, isLocked: Bool) -> some View {
        if isHidden {
            Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.tertiary)
        }
        if isLocked {
            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// Hide and Lock as a pair of menu items, offered on what the place is in
    /// its own right — a subfolder of a hidden folder is hidden without being
    /// hidden itself, and only the ancestor can lift that.
    @ViewBuilder
    private func privacyItems(for item: some PrivacyBearing,
                              hide: @escaping (Bool) async -> Void,
                              lock: @escaping (Bool) async -> Void) -> some View {
        Button(item.isExplicitlyHidden ? "Unhide" : "Hide",
               systemImage: item.isExplicitlyHidden ? "eye" : "eye.slash") {
            Task { await hide(!item.isExplicitlyHidden) }
        }
        Button(item.isExplicitlyLocked ? "Unlock" : "Lock",
               systemImage: item.isExplicitlyLocked ? "lock.open" : "lock") {
            Task { await lock(!item.isExplicitlyLocked) }
        }
    }

    private func spokenPrivacy(isHidden: Bool, isLocked: Bool) -> [String] {
        var parts: [String] = []
        if isHidden { parts.append("Hidden") }
        if isLocked { parts.append("Locked") }
        return parts
    }

    private func spokenCollectionState(_ collection: CollectionSnapshot) -> String {
        var parts = collection.memberCount > 0 ? [Format.itemCount(collection.memberCount)] : []
        parts.append(contentsOf: spokenPrivacy(isHidden: collection.isHidden, isLocked: collection.isLocked))
        return parts.joined(separator: ", ")
    }

    // MARK: Naming

    private func prompt(_ kind: NamingPrompt, initial: String) {
        model.namingPrompt = kind
    }

    // MARK: Bindings

    /// Puts the keyboard where the model says it belongs. Focus is set from
    /// one place so the two columns cannot each believe they have it.
    private func syncFocus() {
        isListFocused = model.keyboardPane == .sidebar
    }

    #if os(macOS)
    /// The keys the sidebar means something particular by. Up and down are
    /// left to the list.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.heldModifiers.subtracting(.shift).isEmpty else { return false }

        switch event.keyCode {
        case MacKey.left: model.collapseOrGoToParent()
        case MacKey.right: model.expandOrEnterCanvas()
        case MacKey.return, MacKey.keypadEnter: model.enterCanvas()
        case MacKey.tab, MacKey.escape: model.focus(.canvas)
        default: return false
        }
        return true
    }
    #endif

    private var selectionBinding: Binding<LibraryDestination?> {
        Binding(
            get: { model.destination },
            set: { value in
                guard let value else { return }
                model.navigate(to: value)
            }
        )
    }

}

/// The folder tree, drawn from expansion state the arrow keys can reach.
///
/// `OutlineGroup` keeps its own expansion privately, which leaves nothing for
/// left and right to open and close.
private struct FolderRows: View {
    let nodes: [FolderNode]
    let model: LibraryModel
    let row: (FolderSnapshot) -> AnyView

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.outlineChildren {
                DisclosureGroup(isExpanded: expansion(of: node.folder.id)) {
                    FolderRows(nodes: children, model: model, row: row)
                } label: {
                    row(node.folder)
                }
            } else {
                row(node.folder)
            }
        }
    }

    private func expansion(of id: FolderID) -> Binding<Bool> {
        Binding(
            get: { model.expandedFolders.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    model.expandedFolders.insert(id)
                } else {
                    model.expandedFolders.remove(id)
                }
            }
        )
    }
}

/// The entity whose appearance is being edited.
struct AppearanceTarget: Identifiable {
    let reference: LibraryReference
    let title: String
    let appearance: EntityAppearance

    var id: UUID { reference.uuid }
}

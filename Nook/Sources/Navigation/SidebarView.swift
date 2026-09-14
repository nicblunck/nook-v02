import SwiftUI
import NookLibrary

/// The library's navigation surface: system destinations, the true folder
/// hierarchy, collections, media types and tags.
///
/// Objects never appear here — the sidebar names places, not things.
///
/// On the Mac the rows are an `NSOutlineView`, the control every Mac sidebar
/// is, so dragging, dropping, opening and closing behave as they do
/// everywhere else on the Mac. The iPad keeps a SwiftUI list. Both name the
/// same places, and everything around them — the footer, the toolbar, the
/// prompts — is shared.
struct SidebarView: View {
    @Bindable var model: LibraryModel

    #if !os(macOS)
    /// The list itself holds the keyboard, rather than an invisible layer
    /// beside it: a list that the system knows is focused paints its own
    /// selection, and recolours the labels and symbols on it for contrast.
    @FocusState private var isListFocused: Bool
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if os(macOS)
        decorated(
            MacSidebar(
                model: model,
                folderTree: model.folderTree,
                collections: model.collections,
                tags: model.tags,
                counts: model.counts,
                presentMediaKinds: model.presentMediaKinds,
                destination: model.destination,
                expandedFolders: model.expandedFolders,
                wantsKeyboard: model.keyboardPane == .sidebar,
                keyboardFocusRequest: model.keyboardFocusRequest,
                onEditAppearance: { model.editingAppearance = $0 }
            )
            // The outline runs the full height of the column and keeps its
            // own content clear of the toolbar, as a Mac sidebar does.
            .ignoresSafeArea(.container, edges: .top)
        )
        #else
        decorated(
            list
                .focused($isListFocused)
                .onAppear { syncFocus() }
                .onChange(of: model.keyboardFocusRequest) { syncFocus() }
                // Clicking a row is another way of saying the keyboard belongs
                // here, and clicking the row you are already on changes no
                // selection — so nothing else would say it.
                .onChange(of: isListFocused) { _, focused in
                    if focused { model.focus(.sidebar) }
                }
        )
        #endif
    }

    /// What surrounds the rows on both platforms.
    private func decorated(_ rows: some View) -> some View {
        rows
            .navigationTitle("Nook")
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .animation(reduceMotion ? nil : NookMotion.reflow,
                       value: model.sidebarReflowRevision)
    }

    #if !os(macOS)
    private var list: some View {
        List(selection: selectionBinding) {
            Section("Library") {
                systemRow(.allObjects, destination: .home,
                          title: "All", symbol: "square.grid.2x2",
                          count: model.counts[.allObjects])
                // Inbox and Favorites are places a drop means something:
                // dropping on Inbox files something out of every folder,
                // dropping on Favorites stars it. Recent and All Objects are
                // queries over the library rather than places in it, so
                // nothing can be put into them.
                systemRow(.inbox, title: "Inbox", symbol: "tray", count: model.counts[.inbox],
                          dropTarget: .folder(nil))
                systemRow(.recent, title: "Recent", symbol: "clock")
                systemRow(.favorites, title: "Favorites", symbol: "star", count: model.counts[.favorites],
                          dropTarget: .favorites)
            }

            Section {
                if model.folderTree.isEmpty {
                    Text("No folders yet").font(.callout).foregroundStyle(.tertiary)
                } else {
                    FolderRows(nodes: model.folderTree, model: model) { folder in
                        folderRow(folder)
                    }
                }
            } header: {
                // The root of the hierarchy. A folder dropped here comes out
                // to the top level; an object dropped here comes out of every
                // folder, which is to say into the Inbox.
                Text("Folders")
                    .libraryDropTarget(.folder(nil), model: model)
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

            if !model.mediaTypes.isEmpty {
                Section("Media Types") {
                    ForEach(model.mediaTypes) { kind in
                        destinationRow(.scope(.kind(kind))) {
                            Label(kind.pluralDisplayName, systemImage: kind.symbolName)
                        }
                    }
                }
            }

            if !model.tags.isEmpty {
                Section("Tags") {
                    TagFlow(spacing: 5) {
                        ForEach(model.tags) { tag in
                            tagRow(tag)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
                }
            }
        }
    }
    #endif

    // MARK: Footer

    /// Destructive storage and hidden-item visibility live at the foot of the
    /// sidebar, separate from the library's destinations.
    private var footer: some View {
        HStack(spacing: 2) {
            footerButton(title: "Recently Deleted",
                         symbol: "trash",
                         isCurrent: model.scope == .recentlyDeleted,
                         count: model.counts[.recentlyDeleted],
                         dropTarget: .trash) {
                model.navigate(to: .scope(.recentlyDeleted))
            }
            // No count on this one. How much someone is keeping out of sight
            // is itself something they are keeping out of sight.
            footerButton(title: "Show Hidden Items",
                         symbol: model.isShowingHiddenContent ? "eye" : "eye.slash",
                         isCurrent: model.isShowingHiddenContent,
                         dropTarget: .hidden) {
                Task { await model.toggleHiddenItems() }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Semi-transparent rather than a solid strip: the sidebar's own
        // material carries on underneath, so the row reads as part of it
        // rather than as a bar bolted to the bottom.
        .background(.ultraThinMaterial)
    }

    /// Icons alone: these are two fixed destinations rather than a list that
    /// grows, and the sidebar is somewhere names are read down a column — a
    /// row of labelled buttons at the foot of it reads as more list.
    private func footerButton(title: String,
                              symbol: String,
                              isCurrent: Bool,
                              count: Int? = nil,
                              dropTarget: DropTarget? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 28, height: 24)
                .background(isCurrent ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 6))
                .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(count.flatMap { $0 > 0 ? Format.itemCount($0) : nil } ?? "")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .modifier(OptionalDropTarget(target: dropTarget, model: model))
    }

    // MARK: Rows

    #if !os(macOS)
    /// The list owns row activation and selection. Keeping the row free of
    /// its own pointer gesture lets the entire label remain a drag destination.
    private func destinationRow<Content: View>(
        _ destination: LibraryDestination,
        @ViewBuilder label: () -> Content
    ) -> some View {
        label()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .tag(destination)
    }

    @ViewBuilder
    private func systemRow(_ scope: LibraryScope,
                           destination: LibraryDestination? = nil,
                           title: String,
                           symbol: String,
                           count: Int? = nil,
                           dropTarget: DropTarget? = nil) -> some View {
        destinationRow(destination ?? .scope(scope)) {
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
            } icon: {
                Image(systemName: symbol)
            }
            // Spoken, the trailing number is just a number: "Inbox, 12" could as
            // easily be a name as a tally. The count becomes the row's value.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(count.flatMap { $0 > 0 ? Format.itemCount($0) : nil } ?? "")
        }
        .modifier(OptionalDropTarget(target: dropTarget, model: model))
    }

    private func folderRow(_ folder: FolderSnapshot) -> some View {
        destinationRow(.scope(.folder(folder.id))) {
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
        }
        .modifier(SidebarFolderDragSource(folderID: folder.id))
        .plopIn(trigger: sidebarArrivalTrigger(for: folder.id),
                order: sidebarArrivalOrder(for: folder.id))
        .transition(sidebarItemTransition)
        .contextMenu {
            Button("Rename…") { prompt(.renameFolder(folder.id), initial: folder.name) }
            Button("New Subfolder…") { model.editingAppearance = .newFolder(parent: folder.id) }
            Button("Customize…") {
                model.editingAppearance = AppearanceTarget(
                    reference: .folder(folder.id), title: folder.name, appearance: folder.appearance
                )
            }
            Divider()
            privacyMenuItems(for: folder,
                             hide: { await model.setHidden($0, forFolder: folder) },
                             lock: { await model.setLocked($0, forFolder: folder) })
            Divider()
            Button("Delete Folder", role: .destructive) {
                Task { await model.deleteFolder(folder.id) }
            }
        }
        // The dedicated modifier establishes a concrete full-row surface.
        // Without it, SwiftUI can register only the label's residual layout as
        // the destination inside a DisclosureGroup.
        .modifier(SidebarFolderDropTarget(folderID: folder.id, model: model))
    }

    private func collectionRow(_ collection: CollectionSnapshot) -> some View {
        destinationRow(.scope(.collection(collection.id))) {
            Label {
                HStack {
                    Text(collection.name)
                    privacyBadges(isHidden: collection.isHidden, isLocked: collection.isLocked)
                    if collection.memberCount > 0 {
                        Spacer()
                        Text("\(collection.memberCount)")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(collection.memberCount)))
                            .motionAware(NookMotion.interaction, value: collection.memberCount)
                    }
                }
            } icon: {
                EntityIcon(appearance: collection.appearance, fallbackSymbol: "rectangle.stack")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(collection.name)
            .accessibilityValue(spokenCollectionState(collection))
        }
        .plopIn(trigger: sidebarArrivalTrigger(for: collection.id),
                order: sidebarArrivalOrder(for: collection.id))
        .transition(sidebarItemTransition)
        .contextMenu {
            Button("Rename…") { prompt(.renameCollection(collection.id), initial: collection.name) }
            Button("Customize…") {
                model.editingAppearance = AppearanceTarget(
                    reference: .collection(collection.id),
                    title: collection.name,
                    appearance: collection.appearance
                )
            }
            Divider()
            // A hidden or locked collection conceals the collection itself.
            // What it gathers stays exactly as reachable as it was: the true
            // folder hierarchy is where storage privacy lives.
            privacyMenuItems(for: collection,
                             hide: { await model.setHidden($0, forCollection: collection) },
                             lock: { await model.setLocked($0, forCollection: collection) })
            Divider()
            Button("Delete Collection", role: .destructive) {
                Task { await model.deleteCollection(collection.id) }
            }
        }
        // A drop here adds a membership. Nothing moves.
        .libraryDropTarget(.collection(collection.id), model: model)
    }

    private func tagRow(_ tag: TagSnapshot) -> some View {
        Button {
            model.navigate(to: .scope(.tag(tag.id)))
        } label: {
            TagPill(tag: tag, isSelected: model.scope == .tag(tag.id))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag.name)
        .accessibilityValue(Format.itemCount(tag.objectCount))
        .tag(LibraryDestination.scope(.tag(tag.id)))
        .contextMenu {
            Button("Rename…") { prompt(.renameTag(tag.id), initial: tag.name) }
            Button("Customize…") {
                model.editingAppearance = AppearanceTarget(
                    reference: .tag(tag.id), title: tag.name, appearance: tag.appearance
                )
            }
            Divider()
            Button("Delete Tag", role: .destructive) {
                Task { await model.deleteTag(tag.id) }
            }
        }
        .libraryDropTarget(.tag(tag.id), model: model)
        .transition(sidebarItemTransition)
    }
    #endif

    // MARK: Privacy

    #if !os(macOS)
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
    #endif

    // MARK: Naming

    #if !os(macOS)
    private var sidebarItemTransition: AnyTransition {
        let movement = AnyTransition.scale(scale: 0.94).combined(with: .opacity)
        return .motionAware(movement, reduceMotion: reduceMotion)
            .animation(reduceMotion ? NookMotion.reduced : NookMotion.reflow)
    }

    private func sidebarArrivalTrigger(for id: FolderID) -> Int? {
        guard let arrival = model.arrival, arrival.folderOrder(id) != nil else { return nil }
        return arrival.revision
    }

    private func sidebarArrivalOrder(for id: FolderID) -> Int {
        model.arrival?.folderOrder(id) ?? 0
    }

    private func sidebarArrivalTrigger(for id: CollectionID) -> Int? {
        guard let arrival = model.arrival, arrival.collectionOrder(id) != nil else { return nil }
        return arrival.revision
    }

    private func sidebarArrivalOrder(for id: CollectionID) -> Int {
        model.arrival?.collectionOrder(id) ?? 0
    }
    #endif

    private func prompt(_ kind: NamingPrompt, initial: String) {
        model.namingPrompt = kind
    }

    // MARK: Bindings

    #if !os(macOS)
    /// Puts the keyboard where the model says it belongs. Focus is set from
    /// one place so the two columns cannot each believe they have it.
    private func syncFocus() {
        isListFocused = model.keyboardPane == .sidebar
    }

    private var selectionBinding: Binding<LibraryDestination?> {
        Binding(
            get: { model.destination },
            set: { value in
                guard let value else { return }
                model.navigate(to: value)
            }
        )
    }
    #endif
}

#if !os(macOS)
/// The folder tree, drawn from expansion state the arrow keys can reach.
///
/// `OutlineGroup` keeps its own expansion privately, which leaves nothing for
/// left and right to open and close.
private struct FolderRows<Row: View>: View {
    let nodes: [FolderNode]
    let model: LibraryModel
    @ViewBuilder let row: (FolderSnapshot) -> Row

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
        .motionAware(NookMotion.reflow, value: model.expandedFolders)
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
#endif

#if !os(macOS)
/// Makes a folder row a native drag source without involving List selection.
private struct SidebarFolderDragSource: ViewModifier {
    let folderID: FolderID

    func body(content: Content) -> some View {
        content.draggable(FolderTransfer(id: folderID))
    }
}

/// Makes the complete folder row the native combined drop destination.
///
/// The enabled overload lets SwiftUI own hit testing and target visualization
/// while the row keeps its independent List selection identity.
private struct SidebarFolderDropTarget: ViewModifier {
    let folderID: FolderID
    let model: LibraryModel

    func body(content: Content) -> some View {
        content.dropDestination(for: LibraryDropItem.self, isEnabled: true) { items, _ in
            Task { await model.accept(items, at: .folder(folderID)) }
        }
    }
}
#endif

/// A drop target on a row or button that may not have one.
///
/// Some of the places named here — Recent, All Objects — are queries rather
/// than places, so they take nothing. The rest light up while a drop is
/// overhead, so they answer the way a folder in the sidebar does.
private struct OptionalDropTarget: ViewModifier {
    let target: DropTarget?
    let model: LibraryModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if let target {
            content
                .background {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.3))
                    }
                }
                .libraryDropTarget(target, model: model) { isTargeted = $0 }
        } else {
            content
        }
    }
}

#if DEBUG
#Preview {
    NavigationSplitView {
        PreviewHost { model in
            SidebarView(model: model)
        }
    } detail: {
        Text("Detail")
    }
    .frame(minWidth: 700, minHeight: 500)
}
#endif

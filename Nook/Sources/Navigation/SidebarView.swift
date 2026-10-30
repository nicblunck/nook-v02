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
    #if os(macOS)
    /// How tall the footer stands, so the outline can scroll its last row
    /// clear of it while the rest pass underneath.
    @State private var footerHeight: CGFloat = 0
    #endif

    var body: some View {
        #if os(macOS)
        decorated(
            MacSidebar(
                model: model,
                folderTree: model.sidebarFolderTree,
                collections: model.sidebarCollections,
                tags: model.sidebarTags,
                counts: model.counts,
                presentMediaKinds: model.presentMediaKinds,
                destination: model.destination,
                expandedFolders: model.expandedFolders,
                isMinimalMode: model.settings.isMinimalMode,
                pinnedPlaces: model.settings.pinnedPlaces,
                wantsKeyboard: model.keyboardPane == .sidebar,
                keyboardFocusRequest: model.keyboardFocusRequest,
                bottomInset: footerHeight,
                // Inside the outline, above its first row, so the cards
                // scroll with the list rather than standing over it.
                header: AnyView(
                    LibraryScopeCards(model: model, selection: model.destination) { destination in
                        // A locked folder authenticates before the canvas
                        // lands on it.
                        if case .scope(.folder(let id)) = destination {
                            Task { await model.openFolder(id, startingPageStack: true) }
                        } else {
                            model.navigate(to: destination, startingPageStack: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                ),
                onEditAppearance: { model.editingAppearance = $0 }
            )
            // Rows fade out as they reach the footer rather than pass under
            // a material: the sidebar is glass over the canvas's accent
            // gradient, and anything laid over the rows would darken it.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: footerHeight + 20)
                }
            }
            // The outline runs the full height of the column and keeps its
            // own content clear of the toolbar, as a Mac sidebar does.
            .ignoresSafeArea(.container, edges: .top)
            // The canvas's accent wash, carried across the sidebar, so the
            // fade the rows go into at the foot is the theme's colour rather
            // than the sidebar's own grey. None in Minimal Mode, as on the
            // canvas.
            .background {
                if !model.settings.isMinimalMode {
                    let accent = model.settings.accentColor ?? .accentColor
                    LinearGradient(colors: [accent.opacity(0.3), accent.opacity(0)],
                                   startPoint: .bottom, endPoint: .top)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
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
            #if os(macOS)
            // Over the outline rather than inset from it: an AppKit scroll
            // view stops where a SwiftUI inset begins, so rows would end at a
            // hard line instead of fading out beneath the footer. The
            // outline keeps its last row clear through `bottomInset`.
            .overlay(alignment: .bottom) {
                footer.onGeometryChange(for: CGFloat.self, of: \.size.height) { footerHeight = $0 }
            }
            #else
            // A bar rather than an inset, so the list gives it the system's
            // soft scroll edge: rows blur away progressively beneath it.
            .safeAreaBar(edge: .bottom, spacing: 0) { footer }
            #endif
            // Rows that stay close up behind one that has left, and only
            // once it has gone.
            .animation(model.sidebarChange.shift(reduceMotion: reduceMotion),
                       value: model.sidebarReflowRevision)
    }

    #if !os(macOS)
    private var list: some View {
        List(selection: selectionBinding) {
            // A section's header rather than a row in it: a row is clipped to
            // the section's rounded corners, which cut into the cards'.
            Section {
            } header: {
                LibraryScopeCards(model: model, selection: model.destination) { destination in
                    selectionBinding.wrappedValue = destination
                }
                .textCase(nil)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                if model.sidebarFolderTree.isEmpty {
                    Text("No folders yet").font(.callout).foregroundStyle(.tertiary)
                } else {
                    FolderRows(nodes: model.sidebarFolderTree, model: model) { folder in
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
                if model.sidebarCollections.isEmpty {
                    Text("No collections yet").font(.callout).foregroundStyle(.tertiary)
                } else {
                    ForEach(model.sidebarCollections) { collection in
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
                        .transition(sidebarItemTransition)
                    }
                }
                .transition(sidebarItemTransition)
            }

            if !model.sidebarTags.isEmpty {
                Section("Tags") {
                    TagFlow(spacing: 5) {
                        ForEach(model.sidebarTags) { tag in
                            tagRow(tag)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
                    .animation(model.sidebarChange.shift(reduceMotion: reduceMotion),
                               value: model.sidebarTags.map(\.id))
                }
                .transition(sidebarItemTransition)
            }
        }
        .animation(model.sidebarChange.shift(reduceMotion: reduceMotion),
                   value: model.mediaTypes)
    }
    #endif

    // MARK: Footer

    /// Destructive storage and hidden-item visibility live at the foot of the
    /// sidebar, separate from the library's destinations.
    private var footer: some View {
        HStack(spacing: 2) {
            footerButtons
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        #if os(macOS)
        // Level with the add-content dock across the window, which sits the
        // same distance off the bottom of the canvas.
        .padding(.top, 6)
        .padding(.bottom, 8)
        #else
        .padding(.vertical, 6)
        #endif
    }

    @ViewBuilder
    private var footerButtons: some View {
        #if os(macOS)
        // On the same glass as the add-content dock at the foot of the
        // library, so the two bottom corners of the window match.
        MacDockCluster { footerDestinations }
        #else
        footerDestinations
        #endif
    }

    @ViewBuilder
    private var footerDestinations: some View {
        footerButton(title: "Trash",
                     symbol: "trash",
                     isCurrent: model.scope == .trash,
                     count: model.counts[.trash],
                     dropTarget: .trash) {
            model.navigate(to: .scope(.trash), startingPageStack: true)
        }
        #if os(macOS)
        Divider()
            .frame(height: 18)
        #endif
        // No count on this one. How much someone is keeping out of sight
        // is itself something they are keeping out of sight.
        footerButton(title: "Hidden",
                     symbol: "eye.slash",
                     isCurrent: model.scope == .hidden,
                     dropTarget: .hidden) {
            Task { await model.openHidden(startingPageStack: true) }
        }
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
            footerIcon(symbol, isCurrent: isCurrent)
        }
        #if os(macOS)
        .buttonStyle(MacAddContentButtonStyle(isSelected: isCurrent))
        #else
        .buttonStyle(.plain)
        #endif
        .motionAware(NookMotion.interaction, value: isCurrent)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(count.flatMap { $0 > 0 ? Format.itemCount($0) : nil } ?? "")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .modifier(OptionalDropTarget(target: dropTarget, model: model))
    }

    @ViewBuilder
    private func footerIcon(_ symbol: String, isCurrent: Bool) -> some View {
        #if os(macOS)
        // The dock's style draws the backing and grows the icon on hover.
        ToolbarIcon.system(symbol).image(size: 16)
        #else
        Image(systemName: symbol)
            .font(.body)
            .frame(width: 28, height: 24)
            .background(isCurrent ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 6))
            .contentShape(.rect(cornerRadius: 6))
        #endif
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

    private func folderRow(_ folder: FolderSnapshot) -> some View {
        destinationRow(.scope(.folder(folder.id))) {
            Label {
                HStack {
                    Text(folder.name)
                    privacyBadges(isHidden: folder.isHidden, isLocked: folder.showsLockBadge,
                                 isLockOpen: folder.isLockOpen)
                }
            } icon: {
                EntityIcon(appearance: folder.appearance, fallbackSymbol: "folder")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(folder.name)
            .accessibilityValue(spokenPrivacy(isHidden: folder.isHidden, isLocked: folder.showsLockBadge,
                                              isLockOpen: folder.isLockOpen)
                .joined(separator: ", "))
        }
        .modifier(SidebarFolderDragSource(folderID: folder.id))
        .plopIn(trigger: sidebarArrivalTrigger(for: folder.id),
                order: sidebarArrivalOrder(for: folder.id),
                delay: model.sidebarChange.enterDelay(reduceMotion: reduceMotion))
        .transition(sidebarItemTransition)
        .contextMenu {
            Button("Rename…") { prompt(.renameFolder(folder.id), initial: folder.name) }
            Button("New Subfolder…") { model.editingAppearance = .newFolder(parent: folder.id) }
            Button("Customize…") {
                model.editingAppearance = AppearanceTarget(
                    reference: .folder(folder.id), title: folder.name, appearance: folder.appearance
                )
            }
            PinMenuItem(settings: model.settings, place: .folder(folder.id))
            Divider()
            privacyMenuItems(for: folder,
                             hide: { await model.setHidden($0, forFolder: folder) },
                             lock: { await model.setLocked($0, forFolder: folder) },
                             lockNow: folder.isLockOpen ? { await model.relockFolders() } : nil)
            Divider()
            Button("Move to Trash", role: .destructive) {
                model.requestMoveToTrash(folder)
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
                    privacyBadges(isHidden: collection.isHidden)
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
                order: sidebarArrivalOrder(for: collection.id),
                delay: model.sidebarChange.enterDelay(reduceMotion: reduceMotion))
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
            PinMenuItem(settings: model.settings, place: .collection(collection.id))
            Divider()
            // A hidden collection conceals the collection itself. What it
            // gathers stays exactly as reachable as it was: the true folder
            // hierarchy is where storage privacy — including locking — lives.
            hideMenuItem(for: collection,
                        hide: { await model.setHidden($0, forCollection: collection) })
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
            model.navigate(to: .scope(.tag(tag.id)), startingPageStack: true)
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
            PinMenuItem(settings: model.settings, place: .tag(tag.id))
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
    private func privacyBadges(isHidden: Bool, isLocked: Bool = false, isLockOpen: Bool = false) -> some View {
        if isHidden {
            Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.tertiary)
        }
        if isLocked {
            Image(systemName: isLockOpen ? "lock.open.fill" : "lock.fill")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func spokenPrivacy(isHidden: Bool, isLocked: Bool = false, isLockOpen: Bool = false) -> [String] {
        var parts: [String] = []
        if isHidden { parts.append("Hidden") }
        if isLocked { parts.append(isLockOpen ? "Locked, open" : "Locked") }
        return parts
    }

    private func spokenCollectionState(_ collection: CollectionSnapshot) -> String {
        var parts = collection.memberCount > 0 ? [Format.itemCount(collection.memberCount)] : []
        parts.append(contentsOf: spokenPrivacy(isHidden: collection.isHidden))
        return parts.joined(separator: ", ")
    }
    #endif

    // MARK: Naming

    #if !os(macOS)
    /// A place leaving shrinks away; one arriving waits until it has gone
    /// and the rows have closed up, then fades in.
    private var sidebarItemTransition: AnyTransition {
        model.sidebarChange.itemTransition(
            exit: .scale(scale: 0.94).combined(with: .opacity),
            enter: .scale(scale: 0.94).combined(with: .opacity),
            reduceMotion: reduceMotion
        )
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
                // A locked folder authenticates before the canvas lands on it,
                // rather than navigating straight to the door.
                if case .scope(.folder(let id)) = value {
                    Task { await model.openFolder(id, startingPageStack: true) }
                } else {
                    model.navigate(to: value, startingPageStack: true)
                }
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
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.3))
                        .opacity(isTargeted ? 1 : 0)
                }
                .motionAware(NookMotion.interaction, value: isTargeted)
                .libraryDropTarget(target, model: model) { isTargeted = $0 }
        } else {
            content
        }
    }
}

// MARK: - Library cards

/// All, Inbox, Recent and Favorites as a two-by-two grid of cards at the top
/// of the sidebar, each with its count, the way Reminders heads its lists.
/// The same grid on every device; `activate` is how each one goes there.
struct LibraryScopeCards: View {
    let model: LibraryModel
    /// The place currently shown, if the sidebar marks one. The iPhone's
    /// list pushes rather than selects, so it passes nil.
    var selection: LibraryDestination?
    let activate: (LibraryDestination) -> Void

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            card(.home, title: "All", symbol: "square.grid.2x2", color: .gray,
                 count: model.counts[.allObjects])
            // Inbox and Favorites are places a drop means something:
            // dropping on Inbox files something out of every folder,
            // dropping on Favorites stars it. Recent and All are queries
            // over the library rather than places in it, so nothing can
            // be put into them.
            card(.scope(.inbox), title: "Inbox", symbol: "tray", color: .blue,
                 count: model.counts[.inbox], dropTarget: .folder(nil))
            card(.scope(.recent), title: "Recent", symbol: "clock", color: .purple)
            card(.scope(.favorites), title: "Favorites", symbol: "star", color: .orange,
                 count: model.counts[.favorites], dropTarget: .favorites)
            ForEach(model.settings.pinnedPlaces, id: \.self) { place in
                pinnedCard(place)
            }
        }
    }

    /// A pinned place, in its own colour and symbol. One that can't be shown
    /// right now — deleted, or hidden while Hidden is closed — leaves no gap
    /// and no card, and comes back if it does.
    @ViewBuilder
    private func pinnedCard(_ place: PinnedPlace) -> some View {
        switch place {
        case .folder(let id):
            if let folder = model.allFolders.first(where: { $0.folder.id == id })?.folder {
                card(place.destination, title: folder.name, appearance: folder.appearance,
                     fallbackSymbol: "folder", fallbackColor: .blue, count: folder.objectCount,
                     dropTarget: .folder(id), pinned: place)
            }
        case .collection(let id):
            if let collection = model.collections.first(where: { $0.id == id }) {
                card(place.destination, title: collection.name, appearance: collection.appearance,
                     fallbackSymbol: "rectangle.stack", fallbackColor: .indigo,
                     count: collection.memberCount, dropTarget: .collection(id), pinned: place)
            }
        case .tag(let id):
            if let tag = model.tags.first(where: { $0.id == id }) {
                card(place.destination, title: tag.name, appearance: tag.appearance,
                     fallbackSymbol: "tag", fallbackColor: .pink, count: tag.objectCount,
                     dropTarget: .tag(id), pinned: place)
            }
        }
    }

    private func card(_ destination: LibraryDestination,
                      title: String,
                      appearance: EntityAppearance,
                      fallbackSymbol: String,
                      fallbackColor: Color,
                      count: Int,
                      dropTarget: DropTarget,
                      pinned: PinnedPlace) -> some View {
        LibraryScopeCard(model: model,
                         title: title,
                         symbol: appearance.symbolName ?? fallbackSymbol,
                         emoji: appearance.emoji,
                         color: Color(hex: appearance.colorHex) ?? fallbackColor,
                         count: count,
                         isSelected: selection == destination,
                         dropTarget: dropTarget) {
            activate(destination)
        }
        .contextMenu { PinMenuItem(settings: model.settings, place: pinned) }
    }

    private func card(_ destination: LibraryDestination,
                      title: String,
                      symbol: String,
                      color: Color,
                      count: Int? = nil,
                      dropTarget: DropTarget? = nil) -> some View {
        LibraryScopeCard(model: model,
                         title: title,
                         symbol: symbol,
                         color: color,
                         count: count,
                         isSelected: selection == destination,
                         dropTarget: dropTarget) {
            activate(destination)
        }
    }
}

private struct LibraryScopeCard: View {
    let model: LibraryModel
    let title: String
    let symbol: String
    var emoji: String? = nil
    let color: Color
    let count: Int?
    let isSelected: Bool
    let dropTarget: DropTarget?
    let action: () -> Void

    @State private var isTargeted = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    /// Minimal Mode drops the colours: plain cards, white in light mode and
    /// dark grey in dark, with the label in the primary colour. Read off the
    /// model rather than the environment, since on the Mac the cards are
    /// hosted apart from the window's SwiftUI and don't inherit it.
    private var isPlain: Bool { model.settings.isMinimalMode }

    private var fill: AnyShapeStyle {
        isPlain ? AnyShapeStyle(.background) : AnyShapeStyle(color.gradient)
    }

    private var ink: Color { isPlain ? .primary : .white }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    if let emoji {
                        Text(emoji).font(.title3)
                    } else {
                        Image(systemName: symbol)
                            .font(.title3.weight(.medium))
                    }
                    Spacer(minLength: 4)
                    if let count {
                        Text("\(count)")
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(count)))
                            .motionAware(NookMotion.interaction, value: count)
                    }
                }
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: shape)
            // A plain card needs an edge of its own against a light sidebar.
            .overlay {
                if isPlain { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
            }
            // The current place is ringed, as a selected row is lit: the
            // card keeps its own colour either way.
            .overlay {
                shape.strokeBorder((isPlain ? Color.primary : .white).opacity(isSelected ? 0.9 : 0), lineWidth: 2.5)
            }
            .overlay {
                shape.fill(ink.opacity(isTargeted ? 0.15 : 0))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .motionAware(NookMotion.interaction, value: isSelected)
        .motionAware(NookMotion.interaction, value: isTargeted)
        .modifier(CardDropTarget(target: dropTarget, model: model, isTargeted: $isTargeted))
        // Spoken, the number is just a number: "Inbox, 12" could as easily
        // be a name as a tally. The count becomes the card's value.
        .accessibilityLabel(title)
        .accessibilityValue(count.flatMap { $0 > 0 ? Format.itemCount($0) : nil } ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// `OptionalDropTarget`'s wash would sit hidden behind a card's own fill, so
/// a card draws its own and only needs to be told when a drop is overhead.
private struct CardDropTarget: ViewModifier {
    let target: DropTarget?
    let model: LibraryModel
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if let target {
            content.libraryDropTarget(target, model: model) { isTargeted = $0 }
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

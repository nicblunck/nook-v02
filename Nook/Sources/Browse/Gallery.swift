import SwiftUI
import NookLibrary

/// The parts every gallery in the app is made of.
///
/// Home and the browsing canvas show different queries, but they are the same
/// kind of surface: objects laid out in the arrangement the user has chosen,
/// each one measurable, selectable and openable. Keeping the layout, the item
/// views, the cursor ring, the resize gesture and the toolbar here is what
/// stops "a grid on Home" and "a grid in a folder" from drifting into two
/// grids — and what lets each layout's own design reach both at once.

// MARK: Metrics

extension LibraryViewMode {
    /// The inset a gallery's contents sit in.
    ///
    /// The list is tighter because its rows carry their own padding and read
    /// as one column, where the two grids read as items on a field.
    var contentInsets: EdgeInsets {
        switch self {
        case .grid, .masonry: EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
        case .list: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        }
    }

    /// Whether the cursor is drawn as a ring around the item.
    ///
    /// The icon grid lights the item itself instead, the way the Finder does;
    /// two highlights on one item would be one too many.
    var drawsCursorRing: Bool { self != .grid }

    /// How far outside the item the ring is drawn. A gap between the picture
    /// and the ring keeps the two readable as separate things where the item
    /// is a full-bleed photograph. Rows sit a hair apart, so they take none.
    var ringOutset: CGFloat { self == .masonry ? 4 : 0 }

    var itemCornerRadius: CGFloat {
        switch self {
        case .grid: 10
        case .masonry: 14
        case .list: 6
        }
    }

    /// A folder is an icon rather than a photograph, so on the masonry wall it
    /// takes the grid's corner rather than the tile's.
    var folderCornerRadius: CGFloat {
        self == .masonry ? 10 : itemCornerRadius
    }
}

// MARK: Layout

/// Items in whichever arrangement the location is set to, at whichever size.
///
/// The caller supplies the items; this decides how they are placed. Every
/// gallery goes through here, so changing what a grid looks like changes it
/// everywhere at once.
struct GalleryLayout<Content: View>: View {
    let mode: LibraryViewMode
    /// How large the user has asked for things to be drawn, as a multiple of
    /// each layout's natural size.
    var scale: Double = 1
    @ViewBuilder let content: Content

    var body: some View {
        switch mode {
        case .grid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth.lowerBound,
                                                   maximum: cellWidth.upperBound),
                                         spacing: 8)],
                      spacing: 14 * min(scale, 1.6)) {
                content
            }
        case .masonry:
            MasonryLayout(minimumColumnWidth: max(130, 168 * scale),
                          spacing: 20 * min(max(scale, 0.75), 1.5)) {
                content
            }
        case .list:
            LazyVStack(spacing: 1) {
                content
            }
        }
    }

    /// The cell holds the icon and two lines of name, and keeps room for the
    /// name even where the icons themselves have been made small.
    private var cellWidth: ClosedRange<CGFloat> {
        let width = 96 * scale
        return max(84, width)...max(112, width * 1.3)
    }
}

/// One object, drawn the way the current arrangement draws it.
struct ObjectItemView: View {
    let object: ObjectSnapshot
    let mode: LibraryViewMode
    let isSelected: Bool
    /// Whether the keyboard is resting here. The grid and the wall each say so
    /// in their own way, and the list leaves it to the ring.
    let isCursor: Bool
    var scale: Double = 1

    var body: some View {
        switch mode {
        case .grid:
            ObjectCard(object: object, isSelected: isSelected,
                       isCursor: isCursor, scale: scale)
        case .masonry:
            ObjectMasonryCard(object: object, isSelected: isSelected,
                              isCursor: isCursor, scale: scale)
        case .list:
            ObjectListRow(object: object, isSelected: isSelected)
        }
    }
}

/// One folder, drawn the way the current arrangement draws it. Masonry has no
/// folder of its own: a folder has no proportions to keep, so it takes the
/// same card the grid gives it.
struct FolderItemView: View {
    let folder: FolderSnapshot
    let mode: LibraryViewMode
    /// The first few things inside, which the icon leafs through when the
    /// pointer rests on it.
    var peeks: [ObjectSnapshot] = []
    let isCursor: Bool
    var scale: Double = 1
    let onOpen: () -> Void

    var body: some View {
        switch mode {
        case .grid:
            // The grid draws no ring, so the card itself has to show that the
            // keyboard is on it.
            FolderCard(folder: folder, peeks: peeks, isHighlighted: isCursor,
                       scale: scale, onOpen: onOpen)
        case .masonry:
            FolderCard(folder: folder, peeks: peeks, scale: scale, onOpen: onOpen)
        case .list:
            FolderListRow(folder: folder).itemClick { onOpen() }
        }
    }
}

// MARK: The cursor

/// Marks one item in a gallery: measures where it sits, and rings it when the
/// keyboard is resting there and the layout wants a ring.
///
/// Generic over the identity because the canvas names items one way and Home
/// names them another, while the ring and the measurement are the same.
private struct GalleryItemMarker<ID: Hashable & Sendable>: ViewModifier {
    let id: ID
    let isCursor: Bool
    let radius: CGFloat
    let outset: CGFloat
    let showsRing: Bool
    let coordinateSpace: String
    @Binding var frames: [ID: CGRect]

    func body(content: Content) -> some View {
        content
            .overlay {
                // Selection is a fill in the list and a mat on the masonry
                // wall; the cursor is this ring, and an item can carry both.
                // A folder, which never joins a selection, has only the ring.
                // The icon grid asks for none: it lights the item instead.
                RoundedRectangle(cornerRadius: radius + outset)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-outset)
                    .opacity(isCursor && showsRing ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(coordinateSpace))
            } action: { frames[id] = $0 }
    }
}

extension View {
    func galleryItem<ID: Hashable & Sendable>(
        _ id: ID,
        isCursor: Bool,
        mode: LibraryViewMode,
        radius: CGFloat,
        in coordinateSpace: String,
        frames: Binding<[ID: CGRect]>
    ) -> some View {
        modifier(GalleryItemMarker(id: id, isCursor: isCursor,
                                   radius: radius, outset: mode.ringOutset,
                                   showsRing: mode.drawsCursorRing,
                                   coordinateSpace: coordinateSpace, frames: frames))
    }
}

// MARK: Behaviour

/// Selection, opening, dragging, reordering and the context menu — applied
/// identically in every view mode and on every gallery, so what an item does
/// never depends on where it is drawn or how.
struct ObjectItemBehavior: ViewModifier {
    let model: LibraryModel
    let object: ObjectSnapshot
    /// Whether this particular item is selected — which only the gallery
    /// knows. Home draws the same object in more than one section, and only
    /// one of those tiles is the one that was clicked.
    let isSelected: Bool
    /// Clicking and arrowing reach the same two calls, so the pointer and the
    /// keyboard cannot drift apart on what a click means. Home and the canvas
    /// differ only in what they name the thing being pointed at.
    let select: (EventModifiers) -> Void
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .itemClick(select: select, open: open)
            .contextMenu {
                ObjectMenu(model: model, objects: targets) { select([]) }
            }
            .draggable(ObjectTransfer(id: object.id, fileURL: model.localURL(for: object)))
            .modifier(ManualReorderTarget(model: model, object: object))
    }

    /// A menu opened on something already selected acts on the whole
    /// selection; opened on anything else it acts on that one thing.
    private var targets: [ObjectSnapshot] {
        isSelected ? model.selectedObjects : [object]
    }
}

/// In a manually ordered collection, dropping one item onto another moves it
/// ahead of that item. Elsewhere — Home included — there is no manual order
/// to rearrange.
private struct ManualReorderTarget: ViewModifier {
    let model: LibraryModel
    let object: ObjectSnapshot

    private var isActive: Bool {
        guard !model.isShowingHome, case .collection = model.scope else { return false }
        return model.sort.field == .manual
    }

    func body(content: Content) -> some View {
        if isActive {
            content.dropDestination(for: ObjectTransfer.self) { transfers, _ in
                Task { await model.reorder(transfers.map(\.id), before: object.id) }
                return true
            }
        } else {
            content
        }
    }
}

/// Dropping objects on a folder relocates them: this is the true hierarchy.
struct FolderDropTarget: ViewModifier {
    let model: LibraryModel
    let folder: FolderSnapshot

    func body(content: Content) -> some View {
        content
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
}

/// Pinching resizes the items, as it does in the Finder's icon view.
///
/// A gallery rather than a canvas thing: making the pictures bigger is the
/// same act on Home as it is in a folder.
struct GalleryResizeGesture: ViewModifier {
    let model: LibraryModel
    /// The size the pinch started from, so the gesture's magnification is
    /// measured against where the user was rather than compounding.
    @State private var scaleAtPinchStart: Double?

    func body(content: Content) -> some View {
        content.gesture(
            MagnifyGesture()
                .onChanged { value in
                    guard model.viewMode.resizesItems else { return }
                    let start = scaleAtPinchStart ?? model.itemScale
                    scaleAtPinchStart = start
                    model.setItemScale(start * value.magnification)
                }
                .onEnded { _ in
                    scaleAtPinchStart = nil
                    Task { await model.commitItemScale() }
                }
        )
    }
}

/// The dashed border shown while files are held over a gallery.
struct GalleryDropIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .padding(8)
            .allowsHitTesting(false)
    }
}

// MARK: Chrome

/// The controls every gallery carries: where you have been, how what you are
/// looking at is arranged, and how things get in.
///
/// Home and the canvas share this rather than each declaring their own, which
/// is what makes the view picker, the size slider and the sort menu mean the
/// same thing on both.
struct GalleryToolbar: ToolbarContent {
    let model: LibraryModel

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        // Preview sits in front of the gallery rather than beside it, so the
        // gallery's own controls stand down while it is open.
        if model.previewedObjectID == nil {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { model.goBack() }
                    .disabled(!model.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { model.goForward() }
                    .disabled(!model.canGoForward)
            }

            ToolbarItem {
                Picker("View", selection: viewModeBinding) {
                    ForEach(LibraryViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
            }

            ToolbarItem {
                GalleryViewOptionsButton(model: model)
            }

            ToolbarItem {
                Menu {
                    Button("Files…", systemImage: "folder") { model.isImporterPresented = true }
                    #if os(iOS)
                    Button("Photos…", systemImage: "photo.on.rectangle") {
                        model.isPhotosPickerPresented = true
                    }
                    #endif
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        Task { await model.importPasteboard() }
                    }
                } label: {
                    Label("Import", systemImage: "plus")
                }
            }
        }

        ToolbarItem {
            Button("Info", systemImage: "info.circle") {
                model.isInspectorPresented.toggle()
            }
        }
    }

    private var viewModeBinding: Binding<LibraryViewMode> {
        Binding(get: { model.viewMode },
                set: { mode in Task { await model.setViewMode(mode) } })
    }
}

/// The Finder's view options: how things are arranged, and how big.
///
/// A panel rather than a menu, because a size control is a slider and a menu
/// has nowhere to put one. It owns the presentation state itself so the
/// toolbar around it can stay stateless and be shared.
private struct GalleryViewOptionsButton: View {
    let model: LibraryModel
    @State private var isPresented = false

    var body: some View {
        Button("View Options", systemImage: "arrow.up.arrow.down") {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            options
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.viewMode.resizesItems {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.3x3.fill").imageScale(.small)
                        Slider(value: itemScaleBinding,
                               in: LocationViewPreferences.itemScaleRange) { isEditing in
                            // One write when the drag ends, rather than one a
                            // frame while it is under way.
                            if !isEditing { Task { await model.commitItemScale() } }
                        }
                        .labelsHidden()
                        Image(systemName: "square.fill").imageScale(.medium)
                    }
                    .foregroundStyle(.secondary)
                }

                Divider()
            }

            Picker("Sort By", selection: sortFieldBinding) {
                ForEach(model.availableSortFields, id: \.self) { field in
                    Text(field.displayName).tag(field)
                }
            }
            Picker("Order", selection: sortAscendingBinding) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            Toggle("Folders First", isOn: foldersFirstBinding)

            Divider()
            // A change stays temporary unless the user says otherwise, so no
            // location quietly acquires a permanent exception.
            if model.canRememberLocation {
                Toggle("Remember for This Location", isOn: rememberBinding)
            }
            Button("Use as Default Everywhere") {
                model.useCurrentPreferencesAsDefault()
            }
        }
        .padding(14)
        .frame(width: 268)
    }

    // MARK: Bindings

    private var sortFieldBinding: Binding<ObjectSortField> {
        Binding(get: { model.sort.field },
                set: { field in
                    Task { await model.setSort(ObjectSort(field: field, ascending: model.sort.ascending)) }
                })
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(get: { model.sort.ascending },
                set: { ascending in
                    Task { await model.setSort(ObjectSort(field: model.sort.field, ascending: ascending)) }
                })
    }

    private var itemScaleBinding: Binding<Double> {
        Binding(get: { model.itemScale },
                set: { scale in model.setItemScale(scale) })
    }

    private var foldersFirstBinding: Binding<Bool> {
        Binding(get: { model.foldersFirst },
                set: { value in Task { await model.setFoldersFirst(value) } })
    }

    private var rememberBinding: Binding<Bool> {
        Binding(get: { model.isRememberingLocation },
                set: { value in Task { await model.setRememberingLocation(value) } })
    }
}

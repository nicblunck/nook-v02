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
}

private extension MasonryCaptionDisplay {
    var layoutRevision: Int {
        switch self {
        case .automatic: 0
        case .always: 1
        case .hidden: 2
        }
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
    var masonryCaptionDisplay: MasonryCaptionDisplay = .automatic
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
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
                              spacing: 20 * min(max(scale, 0.75), 1.5),
                              contentRevision: masonryCaptionDisplay.layoutRevision) {
                    content
                }
            case .list:
                LazyVStack(spacing: 1) {
                    content
                }
            }
        }
        .animation(reduceMotion ? nil : NookMotion.reflow, value: mode)
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
    var masonryCaptionDisplay: MasonryCaptionDisplay = .automatic
    var showsMasonryTypeLabels = true

    var body: some View {
        switch mode {
        case .grid:
            ObjectCard(object: object, isSelected: isSelected,
                       isCursor: isCursor, scale: scale)
        case .masonry:
            ObjectMasonryCard(object: object, isSelected: isSelected,
                              isCursor: isCursor,
                              captionDisplay: masonryCaptionDisplay,
                              showsTypeLabel: showsMasonryTypeLabels,
                              scale: scale)
        case .list:
            ObjectListRow(object: object, isSelected: isSelected)
        }
    }
}

/// One folder, drawn the way the current arrangement draws it.
struct FolderItemView: View {
    let folder: FolderSnapshot
    let mode: LibraryViewMode
    /// The first few things inside, which the icon leafs through when the
    /// pointer rests on it.
    var peeks: [ObjectSnapshot] = []
    let isSelected: Bool
    let isCursor: Bool
    var scale: Double = 1
    var masonryCaptionDisplay: MasonryCaptionDisplay = .automatic
    /// A single click is another way of saying the keyboard belongs to the
    /// canvas and should rest here, the same thing clicking an object says.
    var select: (EventModifiers) -> Void = { _ in }
    let onOpen: () -> Void

    var body: some View {
        Group {
            switch mode {
            case .grid:
                // The grid draws no ring, so the card itself shows selection and
                // the keyboard cursor directly.
                FolderCard(folder: folder, peeks: peeks, isSelected: isSelected,
                           isCursor: isCursor, scale: scale, select: select, onOpen: onOpen)
            case .masonry:
                FolderMasonryCard(folder: folder, peeks: peeks, isSelected: isSelected,
                                  isCursor: isCursor,
                                  captionDisplay: masonryCaptionDisplay,
                                  scale: scale, select: select, onOpen: onOpen)
            case .list:
                FolderListRow(folder: folder, isSelected: isSelected)
                    .itemClick(select: select, open: onOpen)
            }
        }
        .overlay(alignment: .topTrailing) {
            if folder.isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption2.weight(.semibold))
                    .padding(5)
                    .background(.regularMaterial, in: .circle)
                    .padding(6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: The cursor

/// Where the gallery drew each item.
///
/// A reference the gallery writes into, rather than view state, on purpose.
/// Every item reports its frame again whenever the canvas changes width — and
/// the inspector opening changes it on every frame of its animation — so
/// routing those reports through `@State` would re-evaluate, and so re-measure,
/// the whole gallery once per item per frame, which is what made the icons and
/// the masonry wall thrash while the panel came in. Nothing is drawn from these
/// numbers: they are read once, when an arrow key asks what sits above the
/// cursor, so a new one invalidates nothing.
@MainActor
final class GalleryFrames<ID: Hashable & Sendable> {
    private(set) var frames: [ID: CGRect] = [:]

    func record(_ frame: CGRect, for id: ID) {
        frames[id] = frame
    }

    /// Forgets every position, for a change of layout: the old ones describe an
    /// arrangement that is no longer on screen and would answer the next arrow
    /// key from it. Safe only because changing the layout always relays the
    /// gallery, which is what reports the new positions.
    func removeAll() {
        frames.removeAll()
    }

    /// Whatever is still in the gallery has not moved, so its position stands.
    /// Only what has left is dropped, which keeps the map from growing as the
    /// user browses.
    func keep(_ present: Set<ID>) {
        frames = frames.filter { present.contains($0.key) }
    }
}

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
    let frames: GalleryFrames<ID>

    func body(content: Content) -> some View {
        content
            .overlay {
                // Selection is a fill in the list and a mat on the masonry
                // wall; the cursor is this ring, and an item can carry both.
                // The icon grid asks for none: it lights the item instead.
                RoundedRectangle(cornerRadius: radius + outset)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-outset)
                    .opacity(isCursor && showsRing ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .motionAware(NookMotion.interaction, value: isCursor)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(coordinateSpace))
            } action: { frames.record($0, for: id) }
    }
}

extension View {
    func galleryItem<ID: Hashable & Sendable>(
        _ id: ID,
        isCursor: Bool,
        mode: LibraryViewMode,
        radius: CGFloat,
        in coordinateSpace: String,
        frames: GalleryFrames<ID>
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
            .draggable(transfer)
    }

    private var transfer: ObjectTransfer {
        let objects = isSelected ? model.selectedObjects : [object]
        return ObjectTransfer(
            ids: objects.map(\.id),
            fileURL: objects.count == 1 ? model.localURL(for: objects[0]) : nil,
            sourceFolderIDs: objects.map(\.folderID)
        )
    }

    /// A menu opened on something already selected acts on the whole
    /// selection; opened on anything else it acts on that one thing.
    private var targets: [ObjectSnapshot] {
        isSelected ? model.selectedObjects : [object]
    }
}

/// Dropping on a folder relocates: this is the true hierarchy. Objects move
/// into it, subfolders become its children, and files from outside are
/// imported straight into it rather than landing in the Inbox first.
struct FolderDropTarget: ViewModifier {
    let model: LibraryModel
    let folder: FolderSnapshot

    func body(content: Content) -> some View {
        content
            .dropDestination(for: LibraryDropItem.self) { items, _ in
                Task { await model.accept(items, at: .folder(folder.id)) }
                return true
            }
            .externalURLDrop(isTargeted: .constant(false)) { urls in
                Task { await model.importFiles(at: urls, into: .folder(folder.id)) }
            }
    }
}

/// What a gallery does with a drop, and what it shows while one is overhead.
///
/// The dashed outline is a promise that what is being dragged is about to be
/// added to the library, so it is shown only for something arriving from
/// outside Nook. Dragging an item around inside the place it already lives is
/// not an import, and ringing the whole canvas for it says the opposite of
/// what the drop will do — which is nothing.
struct GalleryDropTarget: ViewModifier {
    let model: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var isArrivingFromOutside = true

    func body(content: Content) -> some View {
        content
            .dropDestination(for: LibraryDropItem.self) { items, _ in
                Task { await model.accept(items, at: .currentLocation) }
                return true
            } isTargeted: { isTargeted = $0 }
            .externalURLDrop(isTargeted: $isTargeted) { urls in
                Task { await model.importFiles(at: urls) }
            }
            .modifier(DragOrigin(isArrivingFromOutside: $isArrivingFromOutside))
            .overlay {
                if isTargeted, isArrivingFromOutside {
                    GalleryDropIndicator()
                        .transition(.motionAware(
                            .scale(scale: 0.985).combined(with: .opacity),
                            reduceMotion: reduceMotion
                        ))
                }
            }
            .animation(reduceMotion ? NookMotion.reduced : NookMotion.interaction,
                       value: isTargeted && isArrivingFromOutside)
    }
}

/// Whether the drag overhead started somewhere other than Nook.
///
/// The drop session is what knows: a drag begun in this app carries a local
/// session, one from the Finder does not. Where nothing reports it, a drag is
/// taken at face value and the outline behaves as it always has.
private struct DragOrigin: ViewModifier {
    @Binding var isArrivingFromOutside: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onDropSessionUpdated { session in
            isArrivingFromOutside = session.localSession == nil
        }
        #else
        content
        #endif
    }
}

/// Pinching resizes the items, as it does in the Finder's icon view.
///
/// A gallery rather than a canvas thing: making the pictures bigger is the
/// same act on Home as it is in a folder.
///
/// iOS has no manual size at all — items are sized automatically — so the
/// gesture stands down there rather than fighting the pinch-to-zoom photos
/// and folders already use for other things.
struct GalleryResizeGesture: ViewModifier {
    let model: LibraryModel
    /// The size the pinch started from, so the gesture's magnification is
    /// measured against where the user was rather than compounding.
    @State private var scaleAtPinchStart: Double?

    func body(content: Content) -> some View {
        #if os(iOS)
        content
        #else
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
        #endif
    }
}

/// The neutral wash shown while files are held over a gallery.
struct GalleryDropIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.14))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.gray.opacity(0.28), lineWidth: 1)
            }
            .padding(8)
            .allowsHitTesting(false)
    }
}

/// The library's primary add action. On macOS this is a split button sized to
/// match the window's other toolbar-style controls: the plus opens the system
/// importer directly, while the attached chevron reveals the rest. Elsewhere
/// a regular click opens the importer and a context menu keeps the rest
/// nearby instead.
struct LibraryFloatingActionButton: View {
    let model: LibraryModel
    var fillsAccessory = false

    var body: some View {
        #if os(macOS)
        // `Menu(label:primaryAction:)` renders on macOS as a native
        // NSComboButton-style split control whose height AppKit fixes
        // internally — no SwiftUI frame on the label reaches it. So this is
        // built from two plain, independently-sized glass buttons instead:
        // a real Button for the plus, and a custom-drawn chevron visual
        // layered over an invisible Menu that supplies the actual dropdown.
        // One `.glassEffect()` wraps both segments so they share a single
        // pill sized to hug their combined content, instead of each segment
        // drawing its own separate shape. The glyphs are white, matching the
        // system convention for icons on a colored Liquid Glass fill (e.g.
        // the checkmark on the blue "Done" button).
        HStack(spacing: 0) {
            Button {
                model.isImporterPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1, height: 18)

            ZStack {
                Menu {
                    Button("Add File…", systemImage: "folder") {
                        model.isImporterPresented = true
                    }
                    Button("Add from Photos…", systemImage: "photo.on.rectangle") {
                        model.isPhotosPickerPresented = true
                    }
                    Button("Add URL…", systemImage: "link.badge.plus") {
                        model.isAddURLPresented = true
                    }
                    Divider()
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
                    Color.clear
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)

                // Drawn on top so the Menu above stays purely functional —
                // its own native size is irrelevant since it never paints.
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
            }
            .frame(width: 36, height: 36)
        }
        .glassEffect(.regular.tint(.accentColor).interactive())
        .help("Add content")
        .accessibilityLabel("Add content")
        .accessibilityHint("Opens the Finder to import files. Use the arrow for more options.")
        #else
        Button {
            model.isImporterPresented = true
        } label: {
            if fillsAccessory {
                // The frame belongs on the label, not the button: sizing the
                // button itself only widens its tappable area, leaving the
                // glass style to draw its pill at the label's natural size —
                // centered in that larger area rather than filling it. The
                // label has to be the one asking for all the space so the
                // glass chrome it sits behind grows to match.
                Label("Add Content", systemImage: "plus")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "plus")
            }
        }
        .font(.title2.weight(.semibold))
        .frame(width: fillsAccessory ? nil : 52,
               height: fillsAccessory ? nil : 52)
        .buttonStyle(.glass(.regular.tint(.accentColor).interactive()))
        .tint(.accentColor)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Take Photo", systemImage: "camera") {
                model.isCameraPresented = true
            }
            Button("Scan Document", systemImage: "doc.viewfinder") {
                model.isDocumentScannerPresented = true
            }
            Button("Photo Library", systemImage: "photo.on.rectangle") {
                model.isPhotosPickerPresented = true
            }
            Button("Add URL…", systemImage: "link.badge.plus") {
                model.isAddURLPresented = true
            }
            Divider()
            Button("New Folder…", systemImage: "folder.badge.plus") {
                model.editingAppearance = .newFolder(parent: model.currentFolderID)
            }
            Button("New Collection…", systemImage: "rectangle.stack.badge.plus") {
                model.editingAppearance = .newCollection(adding: [])
            }
            Button("New Tag…", systemImage: "tag") {
                model.editingAppearance = .newTag()
            }
        }
        .help("Add content")
        .accessibilityLabel("Add content")
        .accessibilityHint("Opens the Finder to import files. Control-click for more options.")
        #endif
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
    let showsHistoryControls: Bool

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        // Preview sits in front of the gallery rather than beside it, so the
        // gallery's own controls stand down while it is open.
        if model.previewedObjectID == nil {
            if showsHistoryControls {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.backward") { model.goBack() }
                        .disabled(!model.canGoBack)
                    Button("Forward", systemImage: "chevron.forward") { model.goForward() }
                        .disabled(!model.canGoForward)
                }
            }

            ToolbarItem {
                #if os(iOS)
                // A segmented control reads as three buttons; on iPhone's
                // narrower bar that is one button too many, so the choice
                // moves behind a single one that shows the current mode.
                Menu {
                    Picker("View", selection: viewModeBinding) {
                        ForEach(LibraryViewMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("View", systemImage: model.viewMode.symbolName)
                }
                #else
                Picker("View", selection: viewModeBinding) {
                    ForEach(LibraryViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                #endif
            }

            ToolbarItem {
                GalleryViewOptionsButton(model: model)
            }

            #if os(macOS)
            // On iOS Get Info lives in each item's long-press menu. The
            // preview keeps its own button once an item is open.
            ToolbarItem {
                InfoToolbarButton(model: model)
            }
            #endif
        }
    }

    private var viewModeBinding: Binding<LibraryViewMode> {
        Binding(get: { model.viewMode },
                set: { mode in Task { await model.setViewMode(mode) } })
    }
}

/// Info is a popover hung on its own button, rather than a panel beside the
/// canvas.
///
/// A panel that occupies width has to take that width from something. On
/// macOS that means the window grows to make room, and the split view is
/// re-solved while the window is still growing — which is what threw the
/// sidebar off the leading edge and sent the icons and the masonry wall
/// reflowing. A popover floats above the canvas instead: no column changes
/// width, so nothing is re-measured and nothing reflows. It is also the one
/// presentation that is genuinely the same API on both platforms.
///
/// The cost is that it is transient — clicking the canvas dismisses it — so
/// it answers "what is this?" rather than staying open while the selection
/// is walked. Everything that asks for Get Info lands here: the menu bar,
/// the context menu, the gallery toolbar and the preview toolbar all set the
/// same flag, and whichever of them is on screen is the anchor.
struct InfoToolbarButton: View {
    let model: LibraryModel

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        let button = Button("Info", systemImage: "info.circle") {
            // While previewing, the gallery underneath has not been told what
            // is being looked at, and the panel reads the selection. Naming it
            // here is what makes Get Info describe the previewed object.
            if let previewed = model.previewedObject {
                model.selectPreviewed(previewed)
            }
            model.toggleInspector()
        }

        if showsInfoPopover {
            button.popover(isPresented: infoBinding, arrowEdge: .bottom) {
                InfoPanel(model: model)
                    .frame(width: 340, height: 520)
            }
        } else {
            button
        }
    }

    #if os(iOS)
    /// On iPhone the same content is put up as a sheet by the compact shell, so
    /// the popover stands down rather than racing it for the same flag.
    private var showsInfoPopover: Bool { horizontalSizeClass != .compact }
    #else
    private var showsInfoPopover: Bool { true }
    #endif

    private var infoBinding: Binding<Bool> {
        Binding(get: { model.isInspectorPresented },
                set: { model.setInspector($0) })
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

            if model.viewMode == .masonry {
                MasonryCaptionOption(display: masonryCaptionDisplayBinding)
                Toggle("Type Labels", isOn: showsMasonryTypeLabelsBinding)
                Divider()
            }

            HStack {
                Text("Sort By")
                Spacer()
                Picker("Sort By", selection: sortFieldBinding) {
                    ForEach(model.availableSortFields, id: \.self) { field in
                        Text(field.displayName).tag(field)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            HStack {
                Text("Order")
                Spacer()
                Picker("Order", selection: sortAscendingBinding) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            HStack {
                Text("Folders First")
                    .accessibilityHidden(true)
                Spacer()
                Toggle("Folders First", isOn: foldersFirstBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()
            // A change stays temporary unless the user says otherwise, so no
            // location quietly acquires a permanent exception.
            if model.canRememberLocation {
                HStack {
                    Text("Remember for This Location")
                        .accessibilityHidden(true)
                    Spacer()
                    Toggle("Remember for This Location", isOn: rememberBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
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

    private var masonryCaptionDisplayBinding: Binding<MasonryCaptionDisplay> {
        Binding(get: { model.masonryCaptionDisplay },
                set: { display in Task { await model.setMasonryCaptionDisplay(display) } })
    }

    private var showsMasonryTypeLabelsBinding: Binding<Bool> {
        Binding(get: { model.showsMasonryTypeLabels },
                set: { shows in Task { await model.setShowsMasonryTypeLabels(shows) } })
    }

    private var rememberBinding: Binding<Bool> {
        Binding(get: { model.isRememberingLocation },
                set: { value in Task { await model.setRememberingLocation(value) } })
    }
}

private struct MasonryCaptionOption: View {
    @Binding var display: MasonryCaptionDisplay

    var body: some View {
        #if os(iOS)
        Toggle("Labels", isOn: mobileDisplayBinding)
        #else
        HStack {
            Text("Labels")
            Spacer()
            Picker("Labels", selection: $display) {
                Text("On Hover").tag(MasonryCaptionDisplay.automatic)
                Text("Always On").tag(MasonryCaptionDisplay.always)
                Text("Always Off").tag(MasonryCaptionDisplay.hidden)
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        #endif
    }

    #if os(iOS)
    private var mobileDisplayBinding: Binding<Bool> {
        Binding(
            get: { display != .hidden },
            set: { display = $0 ? .automatic : .hidden }
        )
    }
    #endif
}

import SwiftUI
import NookLibrary
#if os(macOS)
import AppKit
#endif

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
    /// The inset a gallery's contents sit in — the same in every view mode,
    /// so anything anchored to the canvas edge (the Folders First shelf) sits
    /// the same distance in regardless of which arrangement is showing.
    var contentInsets: EdgeInsets {
        EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
    }

    /// Whether the cursor is drawn as a ring around the item.
    ///
    /// The icon grid and the masonry wall light the item itself instead, the
    /// way the Finder does; two highlights on one item would be one too many.
    var drawsCursorRing: Bool { self == .list }

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
    /// Replaces the grid's own adaptive column resolution with an exact
    /// count, computed by the caller from a measured width. Lets something
    /// drawn outside the grid — the Folders First shelf — line up with these
    /// columns instead of guessing at what the grid would have chosen on its
    /// own. The `width` is the caller's to draw that something at; the grid
    /// gets there by sharing its own width equally.
    var fixedColumns: GalleryMetrics.Columns? = nil
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A change of arrangement is a change of container, and a grid
        // cannot be moved into a wall tile by tile — so the arrangement that
        // is leaving fades out, and only then does the new one fade in. The
        // stack keeps the two in the same place while that happens rather
        // than letting the incoming one queue up underneath.
        ZStack(alignment: .top) {
            switch mode {
            case .grid:
                LazyVGrid(columns: gridColumns, spacing: 14 * min(scale, 1.6)) {
                    content
                }
                .transition(arrangementTransition)
            case .masonry:
                MasonryLayout(minimumColumnWidth: max(130, 168 * scale),
                              spacing: 20 * min(max(scale, 0.75), 1.5),
                              contentRevision: masonryCaptionDisplay.layoutRevision) {
                    content
                }
                .transition(arrangementTransition)
            case .list:
                LazyVStack(spacing: 1) {
                    content
                }
                .transition(arrangementTransition)
            }
        }
        .animation(reduceMotion ? nil : NookMotion.reflow, value: mode)
    }

    private var arrangementTransition: AnyTransition {
        .staged(reduceMotion: reduceMotion)
    }

    private var gridColumns: [GridItem] {
        if let fixedColumns {
            // The count is what is pinned; the columns themselves stay
            // flexible so the grid is always exactly as wide as it is
            // offered. Equal shares of that width come out at the caller's
            // `width`, so nothing is lost — and a column that could not give
            // way would hold the grid at its old width when the window is
            // dragged narrower. The width the caller measures would then be
            // that same old width, the count would never come down, and the
            // canvas would be stuck wider than the window for good.
            return Array(repeating: GridItem(.flexible(minimum: 0), spacing: GalleryMetrics.columnSpacing),
                         count: fixedColumns.count)
        }
        let range = GalleryMetrics.cellWidthRange(scale: scale)
        return [GridItem(.adaptive(minimum: range.lowerBound, maximum: range.upperBound),
                         spacing: GalleryMetrics.columnSpacing)]
    }
}

/// The grid's own cell sizing, pulled out from `GalleryLayout` so something
/// laid out beside it — the Folders First shelf — can measure a width and
/// resolve the same columns instead of drifting from whatever the grid
/// actually rendered.
enum GalleryMetrics {
    static let columnSpacing: CGFloat = 8

    struct Columns: Equatable {
        let count: Int
        let width: CGFloat
    }

    /// The cell holds the icon and two lines of name, and keeps room for the
    /// name even where the icons themselves have been made small.
    static func cellWidthRange(scale: Double) -> ClosedRange<CGFloat> {
        let width = 96 * scale
        return max(84, width)...max(112, width * 1.3)
    }

    /// What the grid's own `.adaptive` column would resolve to at this
    /// width: as many columns as fit at the minimum cell width, stretched
    /// no further than the maximum.
    static func resolvedColumns(for availableWidth: CGFloat, scale: Double) -> Columns? {
        guard availableWidth > 0 else { return nil }
        let range = cellWidthRange(scale: scale)
        var count = max(1, Int(((availableWidth + columnSpacing) / (range.lowerBound + columnSpacing)).rounded(.down)))
        var width = (availableWidth - CGFloat(count - 1) * columnSpacing) / CGFloat(count)
        while width > range.upperBound {
            count += 1
            width = (availableWidth - CGFloat(count - 1) * columnSpacing) / CGFloat(count)
        }
        return Columns(count: count, width: width)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .transition(.staged(
                        exit: .scale(scale: 0.6).combined(with: .opacity),
                        enter: .scale(scale: 0.6).combined(with: .opacity),
                        enterDelay: 0,
                        reduceMotion: reduceMotion
                    ))
            }
        }
        .motionAware(NookMotion.interaction, value: folder.isHidden)
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
    let showsRing: Bool
    let coordinateSpace: String
    let frames: GalleryFrames<ID>

    func body(content: Content) -> some View {
        content
            .overlay {
                // Selection is a fill in the list; the cursor is this ring,
                // and a row can carry both. The icon grid and the masonry
                // wall ask for none: they light the item instead.
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
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
                                   radius: radius,
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

#if os(macOS)
/// A dock icon, either an SF Symbol or a full-color custom asset from
/// Assets.xcassets. Custom assets need an explicit size since, unlike SF
/// Symbols, they don't scale with the surrounding font.
private enum ToolbarIcon {
    case system(String)
    case custom(String)

    func image(size: CGFloat) -> some View {
        ToolbarIconView(icon: self, size: size)
    }
}

/// Draws a `ToolbarIcon` at `size`, multiplied by whatever hover scale the
/// enclosing dock button has set. Growing the frame rather than applying a
/// `scaleEffect` matters for the custom assets: a scale effect stretches the
/// bitmap SwiftUI already rasterised at the smaller size, whereas a larger
/// frame has it drawn fresh from the 2x/3x source.
private struct ToolbarIconView: View {
    let icon: ToolbarIcon
    let size: CGFloat
    @Environment(\.dockIconScale) private var scale

    var body: some View {
        let scaled = size * scale
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: scaled, weight: .medium))
        case .custom(let name):
            Image(name)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: scaled, height: scaled)
        }
    }
}

extension EnvironmentValues {
    /// How much a dock button is currently magnifying its icon.
    @Entry fileprivate var dockIconScale: CGFloat = 1
}

/// The library's add-content dock. It borrows the immediacy of the compact
/// iOS bottom toolbar without stretching phone chrome across a Mac window:
/// each common import route remains one click away in a small glass cluster.
struct MacAddContentToolbar: View {
    let model: LibraryModel

    var body: some View {
        HStack(spacing: MacAddContentDock.gutter) {
            MacDocumentPopoverButton(model: model)

            MacAddContentButton(
                title: "Add Photo…",
                icon: .custom("ToolbarGalleryIcon")
            ) {
                model.isPhotosPickerPresented = true
            }

            MacAddContentButton(
                title: "Paste",
                icon: .custom("ToolbarClipboardIcon")
            ) {
                Task { await model.importPasteboard() }
            }

            MacFolderPopoverButton(model: model)
        }
        .padding(MacAddContentDock.gutter)
        // The glass sits beneath the buttons rather than around them: a
        // view wrapped in `glassEffect` is composited into the glass layer
        // so the system can tint it, and that pass softens the full-colour
        // icons, which gain nothing from tinting anyway.
        .background {
            Color.clear.glassEffect(.regular, in: .capsule)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The dock's geometry, shared between the pill and its buttons so the
/// pressed wash lands the same distance from every edge as from its
/// neighbours: a capsule the height of the item, concentric with the pill.
private enum MacAddContentDock {
    static let gutter: CGFloat = 4
    static let itemSize = CGSize(width: 44, height: 32)
    static let hoverScale: CGFloat = 1.15
}

private struct MacDocumentPopoverButton: View {
    let model: LibraryModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ToolbarIcon.custom("ToolbarFileIcon").image(size: 25)
        }
        .buttonStyle(MacAddContentButtonStyle())
        .help("Add Document")
        .accessibilityLabel(Text("Add Document"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                MacAddContentPopoverRow(
                    title: "Add from Files…",
                    icon: .custom("ToolbarFolderIcon")
                ) {
                    isPresented = false
                    model.isImporterPresented = true
                }
                MacAddContentPopoverRow(
                    title: "Scan Document…",
                    icon: .custom("ToolbarScanIcon")
                ) {
                    scanDocument()
                }
            }
            .padding(8)
            .frame(width: 224)
        }
    }

    private func scanDocument() {
        isPresented = false
        Task { @MainActor in
            // Let the popover dismiss before asking the command in the File
            // menu to begin its Continuity Camera handoff.
            await Task.yield()
            guard ContinuityCameraScanner.start() else {
                model.alert = LibraryAlert(
                    title: "No document scanner available",
                    message: "Bring a Continuity Camera-capable iPhone or iPad nearby, then try again."
                )
                return
            }
        }
    }
}

private struct MacFolderPopoverButton: View {
    let model: LibraryModel
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ToolbarIcon.custom("ToolbarFolderIcon").image(size: 25)
        }
        .buttonStyle(MacAddContentButtonStyle())
        .help("Add Folder, Collection, or Tag")
        .accessibilityLabel(Text("Add Folder"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                MacAddContentPopoverRow(
                    title: "Add Folder…",
                    icon: .custom("ToolbarFolderIcon")
                ) {
                    isPresented = false
                    model.editingAppearance = .newFolder(parent: model.currentFolderID)
                }
                MacAddContentPopoverRow(
                    title: "Add Collection…",
                    icon: .custom("ToolbarCollectionIcon")
                ) {
                    isPresented = false
                    model.editingAppearance = .newCollection(adding: [])
                }
                MacAddContentPopoverRow(
                    title: "Add Tag…",
                    icon: .custom("ToolbarTagIcon")
                ) {
                    isPresented = false
                    model.editingAppearance = .newTag()
                }
            }
            .padding(8)
            .frame(width: 224)
        }
    }
}

private struct MacAddContentPopoverRow: View {
    let title: LocalizedStringKey
    let icon: ToolbarIcon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon.image(size: 20)
                Text(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 36)
    }
}

private struct MacAddContentButton: View {
    let title: LocalizedStringKey
    let icon: ToolbarIcon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon.image(size: 25)
        }
        .buttonStyle(MacAddContentButtonStyle())
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

private struct MacAddContentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MacAddContentButtonBody(configuration: configuration)
    }
}

/// The dock button's chrome. A button style cannot watch the pointer
/// itself, so the hover state lives in this view: the icon grows a little
/// under the cursor and settles back when pressed, the cluster's glass
/// staying put beneath it.
private struct MacAddContentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    private var scale: CGFloat {
        if configuration.isPressed { return 1 }
        return isHovering ? MacAddContentDock.hoverScale : 1
    }

    var body: some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .environment(\.dockIconScale, scale)
            .frame(width: MacAddContentDock.itemSize.width,
                   height: MacAddContentDock.itemSize.height)
            .contentShape(.capsule)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0),
                in: .capsule
            )
            .onHover { isHovering = $0 }
            .motionAware(NookMotion.interaction, value: scale)
    }
}

/// Finds the scan command contributed by `ImportFromDevicesCommands` and
/// performs that exact system action. Its result still arrives through the
/// window's `importsItemProviders` modifier.
@MainActor
private enum ContinuityCameraScanner {
    static func start() -> Bool {
        guard let mainMenu = NSApp.mainMenu,
              let importCommand = firstItem(
                in: mainMenu,
                where: { $0.identifier == NSMenuItem.importFromDeviceIdentifier }
              )
        else { return false }

        importCommand.submenu?.update()
        guard let submenu = importCommand.submenu,
              let scanCommand = firstItem(in: submenu, where: isScanCommand),
              let action = scanCommand.action
        else { return false }

        return NSApp.sendAction(action, to: scanCommand.target, from: scanCommand)
    }

    private static func firstItem(
        in menu: NSMenu,
        where matches: (NSMenuItem) -> Bool
    ) -> NSMenuItem? {
        menu.update()
        for item in menu.items {
            if matches(item) { return item }
            if let submenu = item.submenu,
               let match = firstItem(in: submenu, where: matches) {
                return match
            }
        }
        return nil
    }

    private static func isScanCommand(_ item: NSMenuItem) -> Bool {
        let titleMatches = item.title.localizedCaseInsensitiveContains("scan")
        let actionMatches = item.action.map(NSStringFromSelector)?
            .localizedCaseInsensitiveContains("scan") ?? false
        return titleMatches || actionMatches
    }
}
#endif

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

            #if os(macOS)
            ToolbarItem {
                Picker("View", selection: viewModeBinding) {
                    ForEach(LibraryViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
            }
            #endif

            // On iOS the view picker moves into the same popover as the sort
            // and other view options, behind one ellipsis button — one
            // control instead of two on iPhone's narrower bar.
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

    #if os(macOS)
    private var viewModeBinding: Binding<LibraryViewMode> {
        Binding(get: { model.viewMode },
                set: { mode in Task { await model.setViewMode(mode) } })
    }
    #endif
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

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        #if os(iOS)
        // The ellipsis stands for "view and sort options" the same way it
        // does elsewhere in the app, and the popover is pinned compact so
        // iPhone gets a floating panel rather than the system's default
        // full-screen adaptation.
        Button("View Options", systemImage: "ellipsis.circle") {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            options
                .presentationCompactAdaptation(.popover)
        }
        #else
        Button("View Options", systemImage: "arrow.up.arrow.down") {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            options
        }
        #endif
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(iOS)
            // View mode has no toolbar control of its own on iPhone, so it
            // leads the popover rather than the sort options it used to
            // trail behind. A segmented control reads as plain text once
            // three modes are squeezed into it; an icon each reads at a
            // glance and leaves room for the full name underneath.
            HStack(spacing: 8) {
                ForEach(LibraryViewMode.allCases) { mode in
                    ViewModeButton(mode: mode, isSelected: mode == model.viewMode) {
                        Task { await model.setViewMode(mode) }
                    }
                }
            }

            Divider()
            #endif

            // Always present rather than shown only for the view modes they
            // affect — a row appearing or disappearing changes the
            // popover's own height, and that resize is a UIKit animation we
            // do not control and cannot anchor. Greying out an irrelevant
            // row keeps the popover a constant size, which sidesteps the
            // resize (and the jump) entirely.
            //
            // On iPhone the row drops out entirely rather than greying out:
            // horizontalSizeClass doesn't change for the life of the
            // popover, so there's no resize to sidestep, and the narrower
            // bar has no room to spare for a control iPhone doesn't get.
            if showsSizeSlider {
                Group {
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
                .disabled(!model.viewMode.resizesItems)
                .opacity(model.viewMode.resizesItems ? 1 : 0.35)
                .motionAware(NookMotion.interaction, value: model.viewMode)
            }

            Group {
                MasonryCaptionOption(display: masonryCaptionDisplayBinding)
                HStack {
                    Text("Type Labels")
                        .accessibilityHidden(true)
                    Spacer()
                    Toggle("Type Labels", isOn: showsMasonryTypeLabelsBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Divider()
            }
            .disabled(model.viewMode != .masonry)
            .opacity(model.viewMode == .masonry ? 1 : 0.35)
            .motionAware(NookMotion.interaction, value: model.viewMode)

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
                .fixedSize()
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
                    Text("Lock View")
                        .accessibilityHidden(true)
                    Spacer()
                    Toggle("Lock View", isOn: rememberBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
        .padding(14)
        #if os(iOS)
        // A little extra room below the last row, so it doesn't sit flush
        // against the popover's own bottom curve.
        .padding(.bottom, 10)
        // Wide enough for three view-mode buttons side by side without
        // squeezing "Descending" onto two lines below.
        .frame(width: 320)
        #else
        .frame(width: 268)
        #endif
    }

    #if os(iOS)
    /// On iPhone the slider drops out of the popover; iPad keeps it, matching
    /// how `InfoToolbarButton` draws the same line between the two.
    private var showsSizeSlider: Bool { horizontalSizeClass != .compact }
    #else
    private var showsSizeSlider: Bool { true }
    #endif

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

#if os(iOS)
/// One view mode, shown as an icon over its name rather than packed into a
/// segmented control — the same tile shape iOS's own view-options menus use,
/// which also has somewhere to put a name as long as "Masonry Grid".
private struct ViewModeButton: View {
    let mode: LibraryViewMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 20))
                Text(mode.displayName)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                // ConcentricRectangle here read as sharp — nested this far
                // inside a Button's label, it wasn't picking up the
                // popover's declared containerShape. A plain continuous
                // radius, sized to clearly belong to the same rounded
                // family as the card around it, is the reliable version.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color(uiColor: .systemGray5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
#endif

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

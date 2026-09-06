import SwiftUI
import NookLibrary

/// Home's own coordinate space, so tiles in different sections are measured
/// against the same origin and can be compared across them.
private let homeCoordinateSpace = "nook.home"

/// A restrained way back into recent work — not a dashboard.
///
/// Each section is a window onto a place that already exists in the library,
/// so nothing here is a separate store or a separate idea; the heading is a
/// way in. Below the heading it is an ordinary gallery: the same layouts, the
/// same cards, the same selection, the same context menu and the same toolbar
/// as any folder. Home differs from the canvas in what it queries, not in what
/// it is.
struct HomeView: View {
    @Bindable var model: LibraryModel

    /// Where each tile was drawn, which is what tells up and down what the row
    /// above means. Sections are separate galleries stacked in one scroll
    /// view, so no index arithmetic finds the item above one at a section's
    /// top edge — only a measured frame does.
    @State private var tileFrames: [HomeTileID: CGRect] = [:]
    @State private var isDropTargeted = false
    @FocusState private var isHomeFocused: Bool

    var body: some View {
        ZStack {
            // Preview replaces Home exactly as it replaces the canvas, so
            // opening something from here does not send the user somewhere
            // else first.
            if let previewed = model.previewedObject {
                ObjectPreviewView(model: model, object: previewed)
                    .transition(.opacity)
            } else {
                gallery
                    .transition(.opacity)
            }
        }
        .motionAware(.smooth(duration: 0.22), value: model.previewedObjectID)
        .navigationTitle("Home")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { GalleryToolbar(model: model) }
    }

    // MARK: Gallery

    private var gallery: some View {
        Group {
            if model.homeSections.allSatisfy(\.objects.isEmpty) {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        sections
                            // Named on the content rather than the scroll
                            // view, so a tile's measured frame describes where
                            // it sits on Home and does not change as Home
                            // scrolls.
                            .coordinateSpace(.named(homeCoordinateSpace))
                    }
                    #if os(macOS)
                    .onTapGesture {
                        model.focus(.canvas)
                        model.deselectAll()
                    }
                    #endif
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isHomeFocused)
                    .modifier(HomeKeyboard(model: model, frames: tileFrames))
                    // Home is the other thing the canvas pane can be showing,
                    // so it follows the same focus arbitration the canvas does.
                    .onAppear { syncFocus() }
                    .onChange(of: model.keyboardFocusRequest) { syncFocus() }
                    .onChange(of: isHomeFocused) { _, focused in
                        if focused { model.focus(.canvas) }
                    }
                    .onChange(of: model.previewedObjectID) { _, previewed in
                        if previewed == nil { model.focus(.canvas) }
                    }
                    .onChange(of: model.canvasEntryRequest) {
                        model.lightFirstItemIfNothingIsLit()
                    }
                    .onChange(of: model.homeCursor) { _, cursor in
                        guard let cursor else { return }
                        proxy.scrollTo(cursor)
                    }
                    // A different layout is a different set of positions, and
                    // the old ones would answer the next arrow key wrongly.
                    .onChange(of: model.viewMode) { tileFrames = [:] }
                    .onChange(of: model.homeOrder) { _, order in
                        let present = Set(order)
                        tileFrames = tileFrames.filter { present.contains($0.key) }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.importFiles(at: urls) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay { if isDropTargeted { GalleryDropIndicator() } }
    }

    /// The sections, stacked. The inset is the gallery's own, applied once
    /// around the whole column so every heading lines up with the items under
    /// it and with the same edge a folder's contents start at.
    private var sections: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(model.homeSections) { section in
                self.section(section)
            }
        }
        .padding(model.viewMode.contentInsets)
    }

    private func section(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(section)

            if section.objects.isEmpty {
                Text(emptyCopy(for: section))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                GalleryLayout(mode: model.viewMode) {
                    ForEach(section.objects) { object in
                        tile(object, in: section)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The heading is the way into the place the section is a window onto.
    private func heading(_ section: HomeSection) -> some View {
        Button {
            model.navigate(to: .scope(section.scope))
        } label: {
            HStack(spacing: 6) {
                Label(section.title, systemImage: section.symbolName)
                    .font(.title3.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(section.title)")
    }

    private func tile(_ object: ObjectSnapshot, in section: HomeSection) -> some View {
        // The section is part of the tile's identity: Inbox and Recent are
        // separate queries, so the same object is routinely in both, and an
        // object id alone would light two tiles at once.
        let id = HomeTileID(scope: section.scope, object: object.id)
        // The tile is what is selected, not the object: the same photo sits in
        // both Inbox and Recent, and clicking it in one is not clicking it in
        // the other.
        let isSelected = model.homeSelection.contains(id)
        return ObjectItemView(object: object,
                              mode: model.viewMode,
                              isSelected: isSelected)
            // The same rule as the canvas. Home is an entry screen, not a
            // different rulebook: one click selects, two open, and the right
            // button offers everything it offers anywhere else.
            .modifier(ObjectItemBehavior(
                model: model,
                object: object,
                isSelected: isSelected,
                select: { model.selectHomeTile(id, modifiers: $0) },
                open: { model.openHomeTile(id) }
            ))
            .galleryItem(id,
                         isCursor: model.homeCursor == id,
                         radius: model.viewMode.itemCornerRadius,
                         in: homeCoordinateSpace,
                         frames: $tileFrames)
            .id(id)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your Library Is Empty", systemImage: "tray")
        } description: {
            Text("Drag files in, import them, or share something to Nook.")
        } actions: {
            Button("Import Files…") { model.isImporterPresented = true }
        }
    }

    /// Puts the keyboard where the model says it belongs.
    private func syncFocus() {
        isHomeFocused = model.keyboardPane == .canvas
    }

    private func emptyCopy(for section: HomeSection) -> String {
        switch section.scope {
        case .inbox: "Nothing waiting. Anything you import without choosing a folder appears here."
        default: "Nothing yet."
        }
    }
}

/// The keys Home answers to — the canvas's, on Home's own order and frames.
private struct HomeKeyboard: ViewModifier {
    let model: LibraryModel
    let frames: [HomeTileID: CGRect]

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow],
                        phases: [.down, .repeat]) { press in
                guard let direction = CanvasDirection(press.key) else { return .ignored }
                let extending = press.modifiers.contains(.shift)
                let moved = model.moveHomeCursor(direction,
                                                 extendingSelection: extending,
                                                 frames: frames)
                // Left with nowhere left to go steps back into the sidebar,
                // exactly as it does on the canvas.
                if !moved, direction == .left, !extending { model.focus(.sidebar) }
                return .handled
            }
            .onKeyPress(keys: [.home, .end], phases: [.down]) { press in
                model.moveHomeCursorToEdge(press.key == .home ? .up : .down,
                                           extendingSelection: press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.tab) {
                model.focusOtherPane()
                return .handled
            }
            .onKeyPress(.return) {
                guard model.homeCursor != nil else { return .ignored }
                model.openHomeCursorItem()
                return .handled
            }
            .onKeyPress(.space) {
                guard model.canQuickLookHomeCursorItem else { return .ignored }
                model.previewHomeCursorItem()
                return .handled
            }
            .onKeyPress(.escape) {
                guard model.hasSelection else { return .ignored }
                model.deselectAll()
                return .handled
            }
    }
}

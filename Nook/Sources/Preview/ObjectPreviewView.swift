import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

/// A content-first preview that replaces the browsing canvas.
///
/// Only the controls that matter stay: back, favourite, info, and movement to
/// the adjacent object in whatever order the canvas is currently using.
///
/// The objects sit side by side in a paging scroll view, so a swipe — a
/// finger on iOS, two on a trackpad — drags the next one in and settles on
/// it exactly the way the system pages everywhere else. Zooming, playback and
/// scrolling within each page belong to Apple's own viewers.
struct ObjectPreviewView: View {
    let model: LibraryModel
    let object: ObjectSnapshot
    /// Off on a page of the iOS navigation stack, which has the system's own.
    var showsBackButton = true

    @State private var scrolledID: ObjectID?
    @State private var pageKeys = PreviewKeyRegistry()
    #if os(iOS)
    @State private var isChromeHidden = false
    /// Where the bars sit over the full-bleed pages, for the few pages
    /// that must keep clear of them.
    @State private var chromeInsets = EdgeInsets()
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: LibraryModel, object: ObjectSnapshot, showsBackButton: Bool = true) {
        self.model = model
        self.object = object
        self.showsBackButton = showsBackButton
        _scrolledID = State(initialValue: object.id)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pages) { page in
                    PreviewPage(model: model, object: page, isCurrent: page.id == object.id,
                                chromeInsets: pageChromeInsets, keyRegistry: pageKeys,
                                onTap: toggleChrome, onClose: close, onShowInfo: showInfo)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(page.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledID)
        .scrollIndicators(.hidden)
        .scrollDisabled(pages.count < 2)
        .background(.background)
        #if os(iOS)
        // Every page runs under the bars, which float over it, as in Photos;
        // there is no band left behind when they hide.
        .ignoresSafeArea()
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { chromeInsets = $0 }
        .toolbarVisibility(isChromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
        .statusBarHidden(isChromeHidden)
        .animation(reduceMotion ? NookMotion.reduced : NookMotion.interaction, value: isChromeHidden)
        #else
        // In full screen the toolbar slides away and comes back when the
        // pointer reaches the top edge, as it does in Photos and Preview.
        .windowToolbarFullScreenVisibility(.onHover)
        .background(PreviewKeyMonitor(onKey: handle))
        #endif
        .toolbar { toolbarContent }
        // A step from the keyboard or the menu bar moves the pages to it.
        // Where the pages come to rest is what is open now. Read off the
        // resting offset rather than the scroll position binding, which the
        // Mac neither updates for a trackpad swipe nor leaves alone while the
        // pages first lay out. A step from the keyboard comes to rest on the
        // object already open, so it changes nothing here.
        .onScrollPhaseChange { old, phase, context in
            guard phase == .idle, old != .idle else { return }
            let geometry = context.geometry
            guard geometry.containerSize.width > 0 else { return }
            let index = Int((geometry.contentOffset.x / geometry.containerSize.width).rounded())
            let pages = pages
            guard pages.indices.contains(index) else { return }
            settle(on: pages[index])
        }
        .onChange(of: object.id) { _, current in
            guard scrolledID != current else { return }
            withAnimation(reduceMotion ? nil : NookMotion.presentation) { scrolledID = current }
        }
        #if os(iOS)
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { close(); return .handled }
        .onKeyPress(.delete) { model.requestTrashForKeyboard() ? .handled : .ignored }
        #endif
    }

    #if os(macOS)
    /// Photos' keys: Esc and Space go back, Option-Space plays a video, the
    /// arrows step, Z and Command-Plus and -Minus zoom a photo, and Delete
    /// asks before moving it to the Trash.
    private func handle(_ key: PreviewKey) -> Bool {
        let keys = pageKeys.pages[object.id]
        switch key {
        case .escape, .space:
            close()
        case .delete:
            return model.requestTrashForKeyboard()
        case .playPause:
            guard let playPause = keys?.playPause else { return false }
            playPause()
        case .step(let offset):
            step(offset)
        case .zoomToActualSize:
            guard let zoom = keys?.zoomToActualSize else { return false }
            zoom()
        case .zoom(let steps):
            guard let zoom = keys?.zoom else { return false }
            zoom(steps)
        }
        return true
    }
    #endif

    /// Whatever the canvas is showing, in its order. An object opened from
    /// somewhere that order does not cover — a search result, Home — is a
    /// single page on its own.
    private var pages: [ObjectSnapshot] {
        let visible = model.visibleObjects
        return visible.contains(where: { $0.id == object.id }) ? visible : [object]
    }

    private var pageChromeInsets: EdgeInsets {
        #if os(iOS)
        chromeInsets
        #else
        EdgeInsets()
        #endif
    }

    private func toggleChrome() {
        #if os(iOS)
        withAnimation(reduceMotion ? nil : NookMotion.interaction) {
            isChromeHidden.toggle()
        }
        #endif
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsBackButton {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { close() }
            }
        }
        #if os(iOS)
        // Info and Favorite are the two things worth a thumb's reach on a
        // phone, so they ride along the bottom rather than the top bar.
        ToolbarItemGroup(placement: .bottomBar) {
            favoriteButton
            Spacer()
            InfoToolbarButton(model: model)
        }
        #else
        ToolbarItem { favoriteButton }
        ToolbarItem { InfoToolbarButton(model: model) }
        #endif
        ToolbarItem {
            Menu("More", systemImage: "ellipsis.circle") {
                ObjectMenu(model: model, objects: [object])
            }
        }
    }

    private var favoriteButton: some View {
        Button {
            Task { await model.setFavorite(!object.isFavorite, for: [object.id]) }
        } label: {
            Label(object.isFavorite ? "Remove Favorite" : "Favorite",
                  systemImage: object.isFavorite ? "star.fill" : "star")
        }
        .contentTransition(.symbolEffect)
        .motionAware(NookMotion.interaction, value: object.isFavorite)
    }

    // MARK: Actions

    private func close() {
        model.previewedObjectID = nil
    }

    /// Info for what is showing: the sheet on iPhone, the popover elsewhere.
    private func showInfo() {
        model.selectPreviewed(object)
        model.setInspector(true)
    }

    private func settle(on landed: ObjectSnapshot) {
        guard landed.id != object.id else { return }
        model.previewedObjectID = landed.id
        model.selectPreviewed(landed)
    }

    private func step(_ offset: Int) {
        model.stepPreview(offset)
    }
}

/// One object's page: its stored file looked up, then shown in the viewer
/// Apple makes for its kind.
private struct PreviewPage: View {
    let model: LibraryModel
    let object: ObjectSnapshot
    /// Only the page on screen plays; one swiped past stops.
    let isCurrent: Bool
    let chromeInsets: EdgeInsets
    let keyRegistry: PreviewKeyRegistry
    let onTap: () -> Void
    let onClose: () -> Void
    let onShowInfo: () -> Void

    @State private var keys = PreviewPageKeys()
    @State private var resolvedURL: URL?
    @State private var loadFailure: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? NookMotion.reduced : NookMotion.interaction, value: resolvedURL)
        .task(id: object.id) { await resolve() }
        .onAppear { keyRegistry.pages[object.id] = keys }
        .onDisappear {
            if keyRegistry.pages[object.id] === keys { keyRegistry.pages[object.id] = nil }
        }
    }

    @ViewBuilder
    private var content: some View {
        if object.kind == .link {
            // The link's card, kept clear of the bars that float over the
            // full-bleed pages; a tap beside its Open button shows or hides
            // them, as on any other page.
            LinkPreviewView(model: model, object: object)
                .padding(.top, chromeInsets.top)
                .padding(.bottom, chromeInsets.bottom)
                .contentShape(.rect)
                .onTapGesture(perform: onTap)
                .transition(swapTransition)
        } else if let loadFailure {
            ContentUnavailableView("Can't open this item", systemImage: "exclamationmark.triangle",
                                   description: Text(loadFailure))
                .contentShape(.rect)
                .onTapGesture(perform: onTap)
                .transition(swapTransition)
        } else if let resolvedURL {
            FilePreview(object: object, url: resolvedURL, isCurrent: isCurrent, keys: keys,
                        onTap: onTap, onClose: onClose, onShowInfo: onShowInfo)
                .transition(swapTransition)
        } else {
            ProgressView().controlSize(.large)
                .transition(swapTransition)
        }
    }

    private var swapTransition: AnyTransition {
        .staged(reduceMotion: reduceMotion)
    }

    private func resolve() async {
        loadFailure = nil
        // A link has no blob of its own — the page is the content, and
        // `LinkPreviewView` reads `object.sourceURL` directly rather than
        // waiting on a file that was never stored.
        guard object.kind != .link else { return }
        do {
            guard let url = try await model.library.service.originalURL(for: object.id,
                                                                        in: model.accessContext) else {
                loadFailure = "This item has no stored file."
                return
            }
            resolvedURL = url
        } catch {
            loadFailure = error.localizedDescription
        }
    }
}

/// Each kind in Apple's own viewer for it: the platform's zooming scroll
/// view for a photo, PDFKit's continuous scroll for a PDF, AVKit's player for
/// video and audio, and Quick Look for everything else.
private struct FilePreview: View {
    let object: ObjectSnapshot
    let url: URL
    let isCurrent: Bool
    let keys: PreviewPageKeys
    let onTap: () -> Void
    let onClose: () -> Void
    let onShowInfo: () -> Void

    var body: some View {
        if isStillImage {
            #if os(iOS)
            ZoomableImageView(url: url, onTap: onTap, onSwipeUp: onShowInfo)
            #else
            ZoomableImageView(url: url, onClose: onClose, keys: keys)
            #endif
        } else if object.kind == .pdf {
            #if os(iOS)
            PDFKitPreview(url: url, onTap: onTap)
            #else
            PDFKitPreview(url: url)
            #endif
        } else if object.kind == .video || object.kind == .audio {
            #if os(iOS)
            MediaPlayerPreview(url: url, isVideo: object.kind == .video, isCurrent: isCurrent,
                               onTap: onTap)
            #else
            MediaPlayerPreview(url: url, isVideo: object.kind == .video, isCurrent: isCurrent,
                               keys: keys)
            #endif
        } else if canPreview {
            #if os(iOS)
            QuickLookPreview(url: url, onTap: onTap)
            #else
            QuickLookPreview(url: url)
            #endif
        } else {
            ContentUnavailableView {
                Label(object.title, systemImage: object.kind.symbolName)
            } description: {
                Text(Format.caption(for: object))
                Text("A preview isn’t available for this file. You can open it from the info panel.")
            }
        }
    }

    /// Photos and screenshots zoom. An animated GIF stays with Quick Look on
    /// iOS, which plays it; the Mac's image view plays it itself.
    private var isStillImage: Bool {
        guard object.kind == .image || object.kind == .screenshot else { return false }
        #if os(iOS)
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .gif) {
            return false
        }
        #endif
        return true
    }

    private var canPreview: Bool {
        QuickLookPreview.canPreview(url)
    }
}

// MARK: Keys

/// What a page can do with Photos' keys: play a video, zoom a photo. Each
/// page has its own, so a key only ever reaches the page on screen.
@MainActor
final class PreviewPageKeys {
    var playPause: (() -> Void)?
    var zoomToActualSize: (() -> Void)?
    var zoom: ((Int) -> Void)?
}

/// The keys of every page laid out, by the object each page shows.
@MainActor
final class PreviewKeyRegistry {
    var pages: [ObjectID: PreviewPageKeys] = [:]
}

// MARK: Zoom transition

extension EnvironmentValues {
    /// Shared by a navigation stack's gallery tiles and the previews pushed
    /// from them, so iOS can zoom a preview out of its tile and back.
    @Entry var previewZoomNamespace: Namespace.ID? = nil
}

extension View {
    /// Marks a gallery tile as where its object's preview zooms from, with
    /// the corner rounding the tile draws its picture with.
    func previewZoomSource(for id: ObjectID, cornerRadius: CGFloat = 0) -> some View {
        modifier(PreviewZoomSource(id: id, cornerRadius: cornerRadius))
    }

    /// The system's zoom transition for a preview pushed onto the stack: it
    /// grows out of its tile, and dragging it down shrinks it back into the
    /// tile under the finger — the same gesture as closing a photo in Photos.
    func previewZoomTransition(for id: ObjectID?) -> some View {
        modifier(PreviewZoomTransition(id: id))
    }
}

private struct PreviewZoomSource: ViewModifier {
    let id: ObjectID
    let cornerRadius: CGFloat
    @Environment(\.previewZoomNamespace) private var namespace
    #if os(macOS)
    @Environment(\.macPreviewZoom) private var macZoom
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
        #else
        if let macZoom {
            content
                // While its picture is on the way it is not in two places.
                .opacity(macZoom.flight?.object.id == id ? 0 : 1)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(MacPreviewZoom.coordinateSpace))
                } action: { frame in
                    macZoom.tiles[id] = MacPreviewZoom.Tile(frame: frame, cornerRadius: cornerRadius)
                }
                .onDisappear { macZoom.tiles[id] = nil }
        } else {
            content
        }
        #endif
    }
}

private struct PreviewZoomTransition: ViewModifier {
    let id: ObjectID?
    @Environment(\.previewZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace, let id {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

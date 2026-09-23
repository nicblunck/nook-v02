import SwiftUI
import NookLibrary

/// A content-first preview that replaces the browsing canvas.
///
/// Only the controls that matter stay: back, favourite, info, and movement to
/// the adjacent object in whatever order the canvas is currently using.
struct ObjectPreviewView: View {
    let model: LibraryModel
    let object: ObjectSnapshot
    /// Off on a page of the iOS navigation stack, which has the system's own.
    var showsBackButton = true

    @State private var resolvedURL: URL?
    @State private var loadFailure: String?
    #if os(iOS)
    @State private var isChromeHidden = false
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content
        }
        .animation(reduceMotion ? NookMotion.reduced : NookMotion.presentation,
                   value: object.id)
        .animation(reduceMotion ? NookMotion.reduced : NookMotion.interaction,
                   value: resolvedURL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.secondary)
            #if os(macOS)
            .background(HorizontalScrollPaging(isActive: true) { step($0) })
            #endif
            #if os(iOS)
            .gesture(swipeGesture)
            // Only ever reaches content that isn't already an embedded Quick
            // Look, PDFKit or web view — those install their own tap
            // recognizer directly so a tap still toggles the chrome even
            // while the UIKit view underneath owns the touch.
            .onTapGesture(perform: toggleChrome)
            .toolbarVisibility(isChromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
            .statusBarHidden(isChromeHidden)
            .animation(reduceMotion ? NookMotion.reduced : NookMotion.interaction, value: isChromeHidden)
            #endif
            .toolbar { toolbarContent }
            .task(id: object.id) { await resolve() }
            .onKeyPress(.escape) { close(); return .handled }
            .onKeyPress(.leftArrow) { step(-1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
            .onKeyPress(.space) { close(); return .handled }
    }

    #if os(iOS)
    /// A flick left brings in what comes next, the same direction Photos
    /// treats it as; only a swipe that reads as clearly horizontal and
    /// deliberate is allowed to compete with a pinch-zoomed image's own pan.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let translation = value.translation
                guard abs(translation.width) > abs(translation.height) * 1.5,
                      abs(translation.width) > 60
                else { return }
                step(translation.width < 0 ? 1 : -1)
            }
    }
    #endif

    // MARK: Content

    /// Whichever of these is showing gives way to the next in stages — the
    /// spinner fades out before the file fades in, and so on — the same way
    /// the canvas gives way to this view.
    @ViewBuilder
    private var content: some View {
        if object.kind == .link {
            #if os(iOS)
            LinkPreviewView(model: model, object: object, onStep: step, onTap: toggleChrome)
                .transition(swapTransition)
            #else
            LinkPreviewView(model: model, object: object)
                .transition(swapTransition)
            #endif
        } else if let loadFailure {
            ContentUnavailableView("Can't open this item", systemImage: "exclamationmark.triangle",
                                   description: Text(loadFailure))
                .transition(swapTransition)
        } else if let resolvedURL {
            #if os(iOS)
            FilePreview(object: object, url: resolvedURL, onStep: step, onTap: toggleChrome)
                .transition(swapTransition)
            #else
            FilePreview(object: object, url: resolvedURL)
                .transition(swapTransition)
            #endif
        } else {
            ProgressView().controlSize(.large)
                .transition(swapTransition)
        }
    }

    private var swapTransition: AnyTransition {
        .staged(reduceMotion: reduceMotion)
    }

    #if os(iOS)
    private func toggleChrome() {
        withAnimation(reduceMotion ? nil : NookMotion.interaction) {
            isChromeHidden.toggle()
        }
    }
    #endif

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

    private func step(_ offset: Int) {
        model.stepPreview(offset)
    }

    /// Resolves in place rather than clearing `resolvedURL` first.
    ///
    /// Nulling it before every lookup was what sent `FilePreview` briefly
    /// out of the tree and back in on every step — tearing down and rebuilding
    /// the `QLPreviewView` underneath it fast enough to catch AppKit between
    /// closing one and finishing activating the next, which crashes. Handing
    /// the new URL straight to the existing view leaves it in place; only its
    /// `previewItem` changes.
    private func resolve() async {
        loadFailure = nil
        // A link has no blob of its own — the page is the content, and
        // `LinkPreviewView` reads `object.sourceURL` directly rather than
        // waiting on a file that was never stored.
        guard object.kind != .link else {
            resolvedURL = nil
            return
        }
        do {
            guard let url = try await model.library.service.originalURL(for: object.id,
                                                                        in: model.accessContext) else {
                loadFailure = "This item has no stored file."
                resolvedURL = nil
                return
            }
            resolvedURL = url
        } catch {
            loadFailure = error.localizedDescription
            resolvedURL = nil
        }
    }
}

/// A PDF gets PDFKit's own continuous scroll through every page; everything
/// else stored uses the system's interactive Quick Look viewer.
private struct FilePreview: View {
    let object: ObjectSnapshot
    let url: URL
    #if os(iOS)
    var onStep: ((Int) -> Void)? = nil
    var onTap: (() -> Void)? = nil
    #endif

    var body: some View {
        if object.kind == .pdf {
            #if os(iOS)
            PDFKitPreview(url: url, onStep: onStep, onTap: onTap)
            #else
            PDFKitPreview(url: url)
            #endif
        } else if canPreview {
            #if os(iOS)
            QuickLookPreview(url: url, onStep: onStep, onTap: onTap)
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

    private var canPreview: Bool {
        QuickLookPreview.canPreview(url)
    }
}

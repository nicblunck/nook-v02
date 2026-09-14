import SwiftUI
import NookLibrary

/// A content-first preview that replaces the browsing canvas.
///
/// Only the controls that matter stay: back, favourite, info, and movement to
/// the adjacent object in whatever order the canvas is currently using.
struct ObjectPreviewView: View {
    let model: LibraryModel
    let object: ObjectSnapshot

    @State private var resolvedURL: URL?
    @State private var loadFailure: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .transition(.opacity)
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

    @ViewBuilder
    private var content: some View {
        if let loadFailure {
            ContentUnavailableView("Can't open this item", systemImage: "exclamationmark.triangle",
                                   description: Text(loadFailure))
        } else if let resolvedURL {
            FilePreview(object: object, url: resolvedURL)
        } else {
            ProgressView().controlSize(.large)
        }
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") { close() }
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

/// All stored files use the system's interactive Quick Look viewer.
private struct FilePreview: View {
    let object: ObjectSnapshot
    let url: URL

    var body: some View {
        if canPreview {
            QuickLookPreview(url: url)
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

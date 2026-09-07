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

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.secondary)
            .overlay(alignment: .bottom) { navigationControls }
            .toolbar { toolbarContent }
            .task(id: object.id) { await resolve() }
            .onKeyPress(.escape) { close(); return .handled }
            .onKeyPress(.leftArrow) { step(-1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
            .onKeyPress(.space) { close(); return .handled }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let loadFailure {
            ContentUnavailableView("Can't open this item", systemImage: "exclamationmark.triangle",
                                   description: Text(loadFailure))
        } else if let resolvedURL {
            FilePreview(object: object, url: resolvedURL)
                .id(resolvedURL)
        } else {
            ProgressView().controlSize(.large)
        }
    }

    // MARK: Chrome

    private var navigationControls: some View {
        HStack(spacing: 18) {
            Button("Previous", systemImage: "chevron.left") { step(-1) }
                .disabled(model.adjacentObject(to: object.id, offset: -1) == nil)
            Text(object.title)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: 320)
            Button("Next", systemImage: "chevron.right") { step(1) }
                .disabled(model.adjacentObject(to: object.id, offset: 1) == nil)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .padding(.bottom, 20)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Back", systemImage: "chevron.backward") { close() }
        }
        ToolbarItem {
            Button(object.isFavorite ? "Remove Favorite" : "Favorite",
                   systemImage: object.isFavorite ? "star.fill" : "star") {
                Task { await model.setFavorite(!object.isFavorite, for: [object.id]) }
            }
        }
        ToolbarItem {
            Menu("More", systemImage: "ellipsis.circle") {
                ObjectMenu(model: model, objects: [object])
            }
        }
    }

    // MARK: Actions

    private func close() {
        model.previewedObjectID = nil
    }

    private func step(_ offset: Int) {
        model.stepPreview(offset)
    }

    private func resolve() async {
        resolvedURL = nil
        loadFailure = nil
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

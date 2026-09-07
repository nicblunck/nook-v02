import SwiftUI
import UniformTypeIdentifiers
import NookLibrary
#if os(iOS)
import PhotosUI
#endif

/// Sidebar, canvas, and an inspector that stays out of the way until asked for.
struct LibraryWindow: View {
    @Bindable var model: LibraryModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private var navigator: AppNavigator { .shared }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var photoSelections: [PhotosPickerItem] = []
    #endif

    var body: some View {
        shell
            .environment(\.thumbnailLoader, model.library.thumbnails)
            // Importing and exporting are the window's, not the canvas's:
            // Home offers them too, and on iPhone the same prompts are reached
            // from a tab that is not the canvas at all.
            .fileImporter(
                isPresented: $model.isImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                Task { await model.importFiles(at: urls) }
            }
            // Exporting asks for a folder rather than saving one file at a
            // time, because a selection is as ordinary a thing to export as
            // one item.
            .fileImporter(
                isPresented: $model.isExportPickerPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let directory = urls.first else {
                    model.cancelExport()
                    return
                }
                Task { await model.completeExport(to: directory) }
            }
            #if os(iOS)
            .photosPicker(
                isPresented: $model.isPhotosPickerPresented,
                selection: $photoSelections,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: photoSelections) { _, selections in
                guard !selections.isEmpty else { return }
                photoSelections = []
                Task { await importPhotos(selections) }
            }
            #endif
            .alert(item: $model.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
            .alert(item: $model.importFailure) { failure in
                Alert(
                    title: Text("Some items couldn't be imported"),
                    message: Text(failure.message),
                    primaryButton: .default(Text("Retry")) {
                        Task { await model.importItems(failure.items) }
                    },
                    secondaryButton: .cancel()
                )
            }
            .overlay(alignment: .bottom) {
                if let progress = model.importProgress {
                    ImportProgressBar(progress: progress)
                        .padding()
                        // The bar still arrives and still leaves; under Reduce
                        // Motion it does so without sliding up from the edge.
                        .transition(.motionAware(
                            .move(edge: .bottom).combined(with: .opacity),
                            reduceMotion: reduceMotion
                        ))
                }
            }
            .motionAware(.smooth(duration: 0.25), value: model.importProgress?.completed)
            // Global Search floats above whatever is on screen; it does not
            // navigate the canvas to get there.
            .overlay {
                if model.isGlobalSearchPresented {
                    ZStack {
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()
                            .onTapGesture { model.isGlobalSearchPresented = false }
                        GlobalSearchView(model: model) {
                            model.isGlobalSearchPresented = false
                        }
                        .padding(40)
                    }
                    .transition(.opacity)
                }
            }
            .motionAware(.smooth(duration: 0.18), value: model.isGlobalSearchPresented)
            .sheet(isPresented: $model.isSettingsPresented) {
                NavigationStack { SettingsView(settings: model.settings) }
            }
            .modifier(NamingPromptModifier(model: model))
            .focusedSceneValue(\.libraryModel, model)
            // Picks up whatever an intent asked for, including a request that
            // arrived while the app was still launching.
            .task(id: navigator.pending) {
                guard let request = navigator.take() else { return }
                await model.handle(request)
            }
            .environment(model)
    }

    @ViewBuilder
    private var shell: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            CompactLibraryView(model: model)
        } else {
            splitView
        }
        #else
        splitView
        #endif
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
            #if os(macOS)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
            #endif
        } detail: {
            if model.isShowingHome {
                HomeView(model: model)
            } else {
                BrowseView(model: model)
            }
        }
        .inspector(isPresented: inspectorBinding) {
            InfoPanel(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
    }

    /// The inspector is a side panel here; on iPhone the same content comes up
    /// as a sheet instead.
    private var inspectorBinding: Binding<Bool> {
        Binding(get: { model.isInspectorPresented },
                set: { model.isInspectorPresented = $0 })
    }

    #if os(iOS)
    /// Photos hands over bytes rather than a file on disk, so each selection
    /// arrives as data with whatever content type the library holds it in.
    private func importPhotos(_ selections: [PhotosPickerItem]) async {
        var items: [ImportItem] = []
        for selection in selections {
            guard let data = try? await selection.loadTransferable(type: Data.self) else { continue }
            let contentType = selection.supportedContentTypes.first ?? .data
            let name = selection.itemIdentifier.map { "\($0).\(contentType.preferredFilenameExtension ?? "dat")" }
            items.append(.data(data, contentType: contentType, suggestedName: name))
        }
        await model.importItems(items)
    }
    #endif
}

/// Non-blocking progress for a large import; the rest of the app stays usable.
struct ImportProgressBar: View {
    let progress: ImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Importing \(progress.completed + 1) of \(progress.total)")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            if let name = progress.currentItemName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
        }
        .padding(12)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(radius: 12, y: 4)
    }
}

/// Lets the menu bar act on whichever library window is frontmost.
extension FocusedValues {
    @Entry var libraryModel: LibraryModel?
}

struct NookCommands: Commands {
    @FocusedValue(\.libraryModel) private var model

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder…") {
                model?.namingPrompt = .newFolder(parent: model?.currentFolderID)
            }
            .keyboardShortcut("n")
            .disabled(model == nil)

            Button("New Collection…") {
                model?.namingPrompt = .newCollection(adding: [])
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model == nil)

            Divider()

            Button("Import Files…") { model?.isImporterPresented = true }
                .keyboardShortcut("o")
                .disabled(model == nil)

            Button("Export Originals…") {
                guard let model else { return }
                let objects = model.previewedObject.map { [$0] } ?? model.selectedObjects
                model.beginExport(of: objects)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!(model?.canExport ?? false))
        }

        CommandGroup(after: .pasteboard) {
            // Plain Command-V: pasting into a library is pasting, and asking
            // for a modifier on it would make the ordinary case the special
            // one. It stands down while someone is typing — a menu command
            // outranks the field editor, so leaving it enabled would take
            // Command-V away from every text field in the app.
            Button("Paste") {
                guard let model else { return }
                Task { await model.importPasteboard() }
            }
            .keyboardShortcut("v")
            .disabled(model.map(\.isTypingText) ?? true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All") { model?.selectAll() }
                .keyboardShortcut("a")
                .disabled(!(model?.canSelectAll ?? false))

            Button("Deselect All") { model?.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.map { $0.isTypingText || !$0.hasSelection } ?? true)

            Divider()
            Button("Get Info") { model?.isInspectorPresented.toggle() }
                .keyboardShortcut("i")
                .disabled(model == nil)

            Button("Delete") {
                guard let model else { return }
                let ids = Array(model.selectedObjectIDs)
                Task { await model.delete(ids) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!(model?.hasSelection ?? false))

            Button("Toggle Favorite") {
                guard let model else { return }
                let objects = model.previewedObject.map { [$0] } ?? model.selectedObjects
                guard !objects.isEmpty else { return }
                let shouldFavorite = !objects.allSatisfy(\.isFavorite)
                Task { await model.setFavorite(shouldFavorite, for: objects.map(\.id)) }
            }
            .keyboardShortcut(".", modifiers: [])
            .disabled(model.map {
                $0.isTypingText || ($0.previewedObject == nil && !$0.hasSelection)
            } ?? true)
        }

        CommandGroup(after: .toolbar) {
            // Opening, Quick Look and climbing out of a folder are the canvas's
            // own keys given names in the menu bar. They carry Command here
            // because a menu command outranks the field editor: Return, Space
            // and a bare arrow would be taken away from every text field in the
            // app, so those stay on the focused canvas instead.
            Button("Open") { model?.openCurrentItem() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.map { !$0.canOpenCurrentItem || $0.isTypingText } ?? true)

            Button("Quick Look") { model?.previewCurrentItem() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(model.map { !$0.canQuickLookCurrentItem || $0.isTypingText } ?? true)

            Button("Enclosing Folder") { model?.goToEnclosingScope() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.map { !$0.canGoToEnclosingScope || $0.previewedObjectID != nil } ?? true)

            Divider()

            // Back steps out of preview first, then back through the places
            // the user actually visited.
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(model?.canGoBack ?? false))

            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(model?.canGoForward ?? false))

            Divider()

            // Scoped search narrows to where you are; Global Search does not,
            // so they are separate commands rather than one field in two moods.
            Button("Find") { model?.requestSearchFieldFocus() }
                .keyboardShortcut("f")
                .disabled(model == nil)

            Button("Global Search") { model?.isGlobalSearchPresented = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model == nil)

            Divider()

            Button("Previous Item") { model?.stepPreview(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(model?.previewedObjectID == nil)

            Button("Next Item") { model?.stepPreview(1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(model?.previewedObjectID == nil)

            Divider()

            Button("Hidden") {
                guard let model else { return }
                Task { await model.openHidden() }
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button("Recently Deleted") { model?.navigate(to: .scope(.recentlyDeleted)) }
                .disabled(model == nil)

            Divider()

            ForEach(LibraryViewMode.allCases) { mode in
                Button(mode.displayName) {
                    guard let model else { return }
                    Task { await model.setViewMode(mode) }
                }
                .keyboardShortcut(shortcut(for: mode))
                .disabled(model == nil)
            }
        }
    }

    private func shortcut(for mode: LibraryViewMode) -> KeyEquivalent {
        switch mode {
        case .list: "1"
        case .grid: "2"
        case .masonry: "3"
        }
    }
}

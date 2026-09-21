import SwiftUI
import UniformTypeIdentifiers
import NookLibrary
import CoreData
#if os(macOS)
import AppKit
#endif
#if os(iOS) || os(macOS)
import PhotosUI
#endif

/// Sidebar and canvas. Metadata is not a column here: it comes up as a
/// popover on the canvas's own Info button, so asking for it moves nothing.
struct LibraryWindow: View {
    @Bindable var model: LibraryModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isExternalDropTargeted = false
    private var navigator: AppNavigator { .shared }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    #if os(iOS) || os(macOS)
    @State private var photoSelections: [PhotosPickerItem] = []
    #endif

    var body: some View {
        shell
            .environment(\.thumbnailLoader, model.library.thumbnails)
            .externalURLDrop(isTargeted: $isExternalDropTargeted) { urls in
                Task { await model.importFiles(at: urls) }
            }
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
            #if os(macOS)
            // Pairs with `ImportFromDevicesCommands` in `NookCommands`: that
            // puts "Take Photo"/"Scan Document" in the File menu, backed by
            // Continuity Camera, and this is where the captured item lands.
            // A right-click menu can't rely on the same mechanism — SwiftUI's
            // `.contextMenu` doesn't hook into AppKit's menu-item insertion
            // the way an `NSMenu` shown with `popUpContextMenu` does.
            .importsItemProviders([.image, .pdf]) { providers in
                guard let provider = providers.first,
                      let typeIdentifier = provider.registeredTypeIdentifiers().first
                else { return false }
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in await model.importContinuityCameraCapture(data) }
                }
                return true
            }
            #endif
            #if os(iOS) || os(macOS)
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
            #if os(iOS)
            // "Take Photo" and "Scan Document" used to just reopen the file
            // importer; these raise the real system camera and VisionKit's
            // document scanner instead.
            .fullScreenCover(isPresented: $model.isCameraPresented) {
                CameraCaptureView { data in
                    model.isCameraPresented = false
                    guard let data else { return }
                    Task { await model.importCapturedPhoto(data) }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $model.isDocumentScannerPresented) {
                DocumentScannerView { data in
                    model.isDocumentScannerPresented = false
                    guard let data else { return }
                    Task { await model.importScannedDocument(data) }
                }
                .ignoresSafeArea()
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
                    .transition(.motionAware(
                        .scale(scale: 0.96).combined(with: .opacity),
                        reduceMotion: reduceMotion
                    ))
                }
            }
            .animation(reduceMotion ? NookMotion.reduced : NookMotion.presentation,
                       value: model.isGlobalSearchPresented)
            .sheet(isPresented: $model.isAddURLPresented) {
                AddURLView { url in
                    Task { await model.importItems([.link(url)]) }
                }
            }
            .sheet(isPresented: $model.isSettingsPresented) {
                #if os(macOS)
                SettingsView(settings: model.settings)
                #else
                NavigationStack { SettingsView(settings: model.settings) }
                #endif
            }
            .sheet(item: $model.editingAppearance) { target in
                AppearanceEditor(target: target) { name, appearance in
                    switch target.action {
                    case .edit(let reference):
                        await model.updateEntity(reference, name: name, appearance: appearance)
                    case .newFolder(let parent):
                        await model.createFolder(named: name, in: parent, appearance: appearance)
                    case .newCollection(let ids):
                        await model.createCollection(named: name, adding: ids, appearance: appearance)
                    case .newTag(let ids):
                        await model.createTag(named: name, adding: ids, appearance: appearance)
                    }
                }
            }
            .modifier(NamingPromptModifier(model: model))
            .focusedSceneValue(\.libraryModel, model)
            // The standard Edit > Paste command reaches this hook when the
            // library surface owns the keyboard. Text fields keep their own
            // paste behavior, and the guard keeps a focused field from also
            // importing its text into the library.
            #if os(macOS)
            .onPasteCommand(of: [.fileURL, .url, .png, .tiff, .text]) { _ in
                guard !model.isTypingText else { return }
                Task { await model.importPasteboard() }
            }
            #endif
            // Picks up whatever an intent asked for, including a request that
            // arrived while the app was still launching.
            .task(id: navigator.pending) {
                guard let request = navigator.take() else { return }
                await model.handle(request)
            }
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: LibraryModel.libraryDidChange
                ) {
                    guard !Task.isCancelled else { break }
                    await model.refreshAll()
                }
            }
            // A location following the global default rather than remembering
            // its own arrangement is meant to track it live — otherwise a
            // change made in Settings looks like it did nothing until the next
            // navigation happens to reload it.
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: AppSettings.defaultPreferencesDidChange
                ) {
                    guard !Task.isCancelled else { break }
                    await model.loadPreferences()
                    await model.refreshContents()
                }
            }
            .onAppFocusLoss {
                await model.appDidLoseFocus()
            }
            .onAppActivity {
                model.appDidReceiveUserActivity()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSPersistentCloudKitContainer.eventChangedNotification
            )) { notification in
                guard let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event else { return }

                if event.endDate == nil {
                    model.cloudSyncStarted(id: event.identifier)
                } else {
                    Task {
                        await model.cloudSyncFinished(
                            id: event.identifier,
                            succeeded: event.succeeded,
                            error: event.error?.localizedDescription,
                            importedChanges: event.type == .import,
                            at: event.endDate ?? .now
                        )
                    }
                }
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
            BrowseView(model: model)
        }
    }

    #if os(iOS) || os(macOS)
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

private struct AddURLView: View {
    let add: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $address, prompt: Text("https://example.com"))
                        .focused($isAddressFocused)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(submit)
                } footer: {
                    if !address.isEmpty && parsedURL == nil {
                        Text("Enter a valid web address.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add URL")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: submit)
                        .disabled(parsedURL == nil)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 180)
        #endif
        .task { isAddressFocused = true }
    }

    private var parsedURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    private func submit() {
        guard let url = parsedURL else { return }
        add(url)
        dismiss()
    }
}

private struct LastSyncedText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if context.date.timeIntervalSince(date) < 60 {
                Text("Last synced a moment ago")
            } else {
                Text("Last synced \(date, style: .relative)")
            }
        }
    }
}

struct CloudSyncStatusView: View {
    @Bindable var model: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the label is saying, so a change of state can be animated as one.
    private enum State: Equatable {
        case syncing, issue, synced(Date?)
    }

    private var state: State {
        if model.isCloudSyncing { return .syncing }
        if model.cloudSyncError != nil { return .issue }
        return .synced(model.lastCloudSyncDate)
    }

    var body: some View {
        Menu {
            if let error = model.cloudSyncError {
                Label(error, systemImage: "exclamationmark.icloud")
            } else if model.isCloudSyncing {
                Label(
                    "Uploading and downloading changes",
                    systemImage: "arrow.triangle.2.circlepath.icloud"
                )
            } else if let date = model.lastCloudSyncDate {
                LastSyncedText(date: date)
            } else {
                Text("Waiting for the first iCloud sync")
            }
        } label: {
            // One state gives way to the next: "Syncing" fades out before
            // "Last synced" fades in.
            ZStack {
                switch state {
                case .syncing:
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Syncing")
                    }
                    .transition(.staged(reduceMotion: reduceMotion))
                case .issue:
                    Label("Sync issue", systemImage: "exclamationmark.icloud")
                        .transition(.staged(reduceMotion: reduceMotion))
                case .synced(let date):
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.icloud")
                        if let date {
                            LastSyncedText(date: date)
                        } else {
                            Text("iCloud")
                        }
                    }
                    .transition(.staged(reduceMotion: reduceMotion))
                }
            }
            .font(.caption)
            .animation(reduceMotion ? NookMotion.reduced : NookMotion.presentation, value: state)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        if model.isCloudSyncing { return "Syncing with iCloud" }
        if let error = model.cloudSyncError { return "iCloud sync issue: \(error)" }
        if let date = model.lastCloudSyncDate {
            return "Last synced with iCloud \(date.formatted(.relative(presentation: .named)))"
        }
        return "iCloud is waiting to sync"
    }
}

/// Non-blocking progress for a large import; the rest of the app stays usable.
struct ImportProgressBar: View {
    let progress: ImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Importing \(progress.completed + 1) of \(progress.total)")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(progress.completed)))
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

/// A compact confirmation that floats above the gallery's bottom center.
struct LibraryToastView: View {
    let toast: LibraryToast

    var body: some View {
        HStack(spacing: 8) {
            ToastIcon(systemImage: toast.systemImage, tint: toast.tint.color)
            Text(toast.message)
                .lineLimit(2)
        }
        .font(.callout.weight(.medium))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule()
                .stroke(.primary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }
}

private struct ToastIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.3))
                .frame(width: 24, height: 24)
                .blur(radius: 5)

            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .shadow(color: tint.opacity(0.9), radius: 5)
        }
        .frame(width: 24, height: 24)
    }
}

private extension LibraryToastTint {
    var color: Color {
        switch self {
        case .green: .green
        case .blue: .blue
        case .yellow: .yellow
        case .purple: .purple
        case .orange: .orange
        case .red: .red
        }
    }
}

/// Lets the menu bar act on whichever library window is frontmost.
extension FocusedValues {
    @Entry var libraryModel: LibraryModel?
}

struct NookCommands: Commands {
    @FocusedValue(\.libraryModel) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Commands {
        #if os(macOS)
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",")
        }
        #endif

        CommandGroup(replacing: .newItem) {
            #if os(macOS)
            Button("New Window") {
                openWindow(id: "library")
            }
            .keyboardShortcut("n")

            Button("New Tab") {
                NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("t")

            Divider()
            #endif

            Button("New Folder…") {
                model?.editingAppearance = .newFolder(parent: model?.currentFolderID)
            }
            .keyboardShortcut("n")
            .disabled(model == nil)

            Button("New Collection…") {
                model?.editingAppearance = .newCollection(adding: [])
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button("New Tag…") {
                model?.editingAppearance = .newTag()
            }
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
            // Let the focused search/name/notes field keep Command-V for text.
            .disabled(model?.isTypingText ?? true)
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
            Button("Get Info") { model?.toggleInspector() }
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
            Button("Open") { Task { await model?.openCurrentItem() } }
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

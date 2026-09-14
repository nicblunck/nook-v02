import SwiftUI
import NookLibrary

@main
struct NookApp: App {
    @State private var settings = AppSettings()
    @State private var loader = LibraryLoader()

    var body: some Scene {
        WindowGroup(id: "library") {
            RootView(loader: loader, settings: settings)
                .tint(settings.accentColor)
                .preferredColorScheme(settings.appearance.colorScheme)
            #if os(macOS)
                .frame(minWidth: 680, minHeight: 400)
            #endif
        }
        .commands {
            NookCommands()
            #if os(macOS)
            // Puts "Take Photo"/"Scan Document" in the File menu, backed by
            // Continuity Camera. The item only appears once macOS has a
            // camera-capable iPhone/iPad nearby to offer.
            ImportFromDevicesCommands()
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif

        // Use a singleton window so Settings can have a unified toolbar and
        // normal resizing. NookCommands supplies the standard app-menu item
        // and Command-comma shortcut.
        #if os(macOS)
        Window("Settings", id: "settings") {
            SettingsView(settings: settings)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        #endif
    }
}

/// Opens the library once, on launch, and hands the rest of the app a model.
@MainActor
@Observable
final class LibraryLoader {
    enum State {
        case loading
        case ready(Library)
        case failed(String)
    }

    private(set) var state: State = .loading

    func load(settings: AppSettings) async {
        guard case .loading = state else { return }
        do {
            // Shared, so an App Intent that ran first does not leave the app
            // opening a second container over the same store.
            let library = try await SharedLibrary.shared.current()
            // Objects past their retention window go now rather than lingering.
            try? await library.service.purgeExpiredDeletions()
            // The store is shared, but the navigation model is intentionally
            // created by each window. This keeps folders, search, selection and
            // history independent across windows and tabs.
            let startupModel = LibraryModel(library: library, settings: settings)
            await startupModel.refreshAll()
            state = .ready(library)

            // Catch up on anything the share extension left for the app to
            // finish, and on any backlog from a previous launch.
            startupModel.extractPendingContent()

            // Files imported while iCloud Documents was unavailable live in
            // the app-group fallback. Promote them without delaying launch.
            Task {
                await library.service.migrateLocallyAvailableBlobsToCloud()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct RootView: View {
    let loader: LibraryLoader
    let settings: AppSettings
    @State private var model: LibraryModel?

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                ProgressView().controlSize(.large)
            case .ready:
                if let model {
                    LibraryWindow(model: model)
                } else {
                    ProgressView().controlSize(.large)
                }
            case .failed(let message):
                ContentUnavailableView(
                    "Nook couldn't open your library",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .task { await loader.load(settings: settings) }
        .task(id: readyLibraryURL) {
            guard model == nil, case .ready(let library) = loader.state else { return }
            let windowModel = LibraryModel(library: library, settings: settings)
            await windowModel.refreshAll()
            guard !Task.isCancelled else { return }
            model = windowModel
            windowModel.extractPendingContent()
            windowModel.fetchPendingLinkMetadata()
        }
    }

    private var readyLibraryURL: URL? {
        guard case .ready(let library) = loader.state else { return nil }
        return library.locations.root
    }
}

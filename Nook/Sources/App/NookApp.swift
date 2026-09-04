import SwiftUI
import NookLibrary

@main
struct NookApp: App {
    @State private var loader = LibraryLoader()

    var body: some Scene {
        WindowGroup {
            RootView(loader: loader)
            #if os(macOS)
                .frame(minWidth: 860, minHeight: 560)
            #endif
        }
        .commands { NookCommands() }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif
    }
}

/// Opens the library once, on launch, and hands the rest of the app a model.
@MainActor
@Observable
final class LibraryLoader {
    enum State {
        case loading
        case ready(LibraryModel)
        case failed(String)
    }

    private(set) var state: State = .loading

    func load() async {
        guard case .loading = state else { return }
        do {
            let locations = try LibraryLocations.applicationDefault()
            let library = try await Library.bootstrap(locations: locations)
            // Objects past their retention window go now rather than lingering.
            try? await library.service.purgeExpiredDeletions()
            let model = LibraryModel(library: library)
            await model.refreshAll()
            state = .ready(model)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct RootView: View {
    let loader: LibraryLoader

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                ProgressView().controlSize(.large)
            case .ready(let model):
                LibraryWindow(model: model)
            case .failed(let message):
                ContentUnavailableView(
                    "Nook couldn't open your library",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .task { await loader.load() }
    }
}

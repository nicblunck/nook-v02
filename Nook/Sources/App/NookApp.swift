import SwiftUI
import NookLibrary

@main
struct NookApp: App {
    @State private var settings = AppSettings()
    @State private var loader = LibraryLoader()

    #if DEBUG
    init() {
        // One-off maintenance before a CloudKit schema deploy; see
        // Documentation/releasing.md. Exits before any window opens.
        if ProcessInfo.processInfo.arguments.contains("-NookInitializeCloudKitSchema") {
            do {
                try CloudKitSchemaInitializer.initializeDevelopmentSchema()
                print("CloudKit Development schema initialized")
                exit(0)
            } catch {
                print("CloudKit schema initialization failed: \(error)")
                exit(1)
            }
        }
    }
    #endif

    var body: some Scene {
        WindowGroup(id: "library") {
            RootView(loader: loader, settings: settings)
                .tint(settings.accentColor)
                .environment(\.isMinimalMode, settings.isMinimalMode)
                .environment(\.entityDefaultColor, settings.chosenAccentColor)
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

    /// Close enough to launch, since the app makes its loader first.
    private let launchedAt = ContinuousClock.now

    /// Holds the splash until it has been up for its minimum time, so a fast
    /// launch doesn't flash the mark and snatch it away again.
    func waitOutSplash() async {
        try? await Task.sleep(until: launchedAt + SplashView.minimumDuration)
    }

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
    /// Whether the splash still covers this window. Every window opens under
    /// it, so none waits on a bare spinner while its library loads.
    @State private var isShowingSplash = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                Color.clear
            case .ready:
                if let model {
                    LibraryWindow(model: model)
                } else {
                    Color.clear
                }
            case .failed(let message):
                ContentUnavailableView(
                    "Nook couldn't open your library",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .overlay {
            if isShowingSplash {
                SplashView(accentColor: settings.accentColor ?? .accentColor,
                           showsWash: !settings.isMinimalMode)
                    .transition(.motionAware(SplashView.transition, reduceMotion: reduceMotion))
            }
        }
        #if os(macOS)
        // The splash is a plain screen: no window title or toolbar over it.
        .toolbar(removing: isShowingSplash ? .title : nil)
        .toolbarVisibility(isShowingSplash ? .hidden : .automatic, for: .windowToolbar)
        #endif
        .task { await loader.load(settings: settings) }
        .task(id: isLaunchFinished) {
            guard isLaunchFinished, isShowingSplash else { return }
            // Long since past for a window opened after launch.
            await loader.waitOutSplash()
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? NookMotion.reduced : SplashView.exit) {
                isShowingSplash = false
            }
        }
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

    /// The window has something to show in place of the splash: the library,
    /// or the reason it couldn't be opened.
    private var isLaunchFinished: Bool {
        if case .failed = loader.state { return true }
        return model != nil
    }

    private var readyLibraryURL: URL? {
        guard case .ready(let library) = loader.state else { return nil }
        return library.locations.root
    }
}

/// The launch screen, carried on into the app until the library is open.
///
/// On iOS the system shows `SplashMark` over `SplashBackground` before the
/// app draws anything (UILaunchScreen in the Info.plist). This draws the same
/// image at the same size in the same place, so the hand-off can't be seen,
/// and then the mark lifts away to reveal the library underneath.
struct SplashView: View {
    static let minimumDuration: Duration = .milliseconds(600)
    static let exit = Animation.easeInOut(duration: 0.5)

    /// The Mac's splash sits on the library's own backdrop, so it fades
    /// straight into the window rather than lifting away as on iOS.
    static var transition: AnyTransition {
        #if os(macOS)
        .opacity
        #else
        .opacity.combined(with: .scale(scale: 1.12))
        #endif
    }

    /// The tint of the gradient the library draws behind its canvas.
    let accentColor: Color
    /// Off in Minimal Mode, where the canvas has no wash either.
    var showsWash = true

    var body: some View {
        ZStack {
            background
            #if os(macOS)
            // The same wash as the canvas, so the library appears in place.
            if showsWash {
                LinearGradient(colors: [accentColor.opacity(0.3), accentColor.opacity(0)],
                               startPoint: .bottom, endPoint: .top)
            }
            #endif
            // Not resizable: drawn at its point size, as the launch screen does.
            Image("SplashMark")
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Opening Nook")
    }

    private var background: Color {
        #if os(macOS)
        // A Mac window has no launch screen to match, only its own background.
        Color(nsColor: .windowBackgroundColor)
        #else
        Color("SplashBackground")
        #endif
    }
}

#if DEBUG
#Preview("Splash") {
    SplashView(accentColor: .accentColor)
        .frame(width: 900, height: 600)
}
#endif

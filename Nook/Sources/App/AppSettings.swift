import SwiftUI
import NookLibrary

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// How long hidden items stay revealed while the app receives no user input.
enum HiddenRevealTimeout: String, CaseIterable, Identifiable {
    case never
    case after30Seconds
    case after1Minute
    case after5Minutes
    case after15Minutes

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .never: "Never"
        case .after30Seconds: "After 30 Seconds"
        case .after1Minute: "After 1 Minute"
        case .after5Minutes: "After 5 Minutes"
        case .after15Minutes: "After 15 Minutes"
        }
    }

    /// How much inactivity to allow before hiding items again, or nil to keep
    /// them revealed until the user turns the toggle off or the process ends.
    var duration: Duration? {
        switch self {
        case .never: nil
        case .after30Seconds: .seconds(30)
        case .after1Minute: .seconds(60)
        case .after5Minutes: .seconds(300)
        case .after15Minutes: .seconds(900)
        }
    }
}

/// Where a link goes when it is opened on iOS.
enum LinkOpening: String, CaseIterable, Identifiable {
    /// Out to wherever the user's browsing actually happens.
    case defaultBrowser
    /// Into Safari's own sheet over Nook, which Done closes again.
    case inApp

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .defaultBrowser: "Default Browser"
        case .inApp: "Nook"
        }
    }
}

/// Where the iPhone opens, and where its Home button goes back to.
///
/// Anything other than the Library list is pushed on top of it, so the back
/// button still reaches the list from there.
enum StartPage: Hashable {
    /// The Library list itself, with nothing pushed.
    case library
    case all
    case inbox
    case recent
    case favorites
    case folder(FolderID)

    /// What the canvas shows, or nil for the Library list.
    var destination: LibraryDestination? {
        switch self {
        case .library: nil
        case .all: .home
        case .inbox: .scope(.inbox)
        case .recent: .scope(.recent)
        case .favorites: .scope(.favorites)
        case .folder(let id): .scope(.folder(id))
        }
    }

    fileprivate var rawValue: String {
        switch self {
        case .library: "library"
        case .all: "all"
        case .inbox: "inbox"
        case .recent: "recent"
        case .favorites: "favorites"
        case .folder(let id): "folder:\(id.uuid.uuidString)"
        }
    }

    fileprivate init?(rawValue: String) {
        switch rawValue {
        case "library": self = .library
        case "all": self = .all
        case "inbox": self = .inbox
        case "recent": self = .recent
        case "favorites": self = .favorites
        default:
            guard rawValue.hasPrefix("folder:"),
                  let id = FolderID(uuidString: String(rawValue.dropFirst("folder:".count)))
            else { return nil }
            self = .folder(id)
        }
    }
}

/// The SF Symbol each full-colour add icon becomes in Minimal Mode.
enum MinimalSymbol {
    static func replacing(_ customIcon: String) -> String {
        switch customIcon {
        case "ToolbarFileIcon": "doc"
        case "ToolbarGalleryIcon": "photo.on.rectangle"
        case "ToolbarClipboardIcon": "doc.on.clipboard"
        case "ToolbarFolderIcon": "folder"
        case "ToolbarScanIcon": "doc.viewfinder"
        case "ToolbarCollectionIcon": "rectangle.stack"
        case "ToolbarTagIcon": "tag"
        case "ToolbarCameraIcon": "camera"
        default: "square.dashed"
        }
    }
}

extension EnvironmentValues {
    /// Whether Minimal Mode is on, for views that have no model to ask.
    @Entry var isMinimalMode = false
    /// What a folder, collection or tag with no colour of its own is drawn
    /// in: the chosen accent, even in Minimal Mode. `Color.accentColor`
    /// follows the interface's tint, which Minimal Mode turns black.
    @Entry var entityDefaultColor: Color = .blue
}

/// A folder, collection or tag pinned as a card at the top of the sidebar,
/// under All, Inbox, Recent and Favorites.
enum PinnedPlace: Codable, Hashable {
    case folder(FolderID)
    case collection(CollectionID)
    case tag(TagID)

    /// Room for one more row of two beneath the four fixed cards.
    static let limit = 4

    var scope: LibraryScope {
        switch self {
        case .folder(let id): .folder(id)
        case .collection(let id): .collection(id)
        case .tag(let id): .tag(id)
        }
    }

    var destination: LibraryDestination { .scope(scope) }
}

/// The global defaults every location follows until one is explicitly told to
/// remember something else.
///
/// Kept deliberately small. A location's own arrangement is stored with that
/// location in the library; this is only the fallback, so a fresh folder always
/// looks like the user's current preference rather than like whatever the last
/// folder happened to be set to.
@MainActor
@Observable
final class AppSettings {
    /// Posted whenever `defaultPreferences` changes, so a location that is
    /// following it rather than remembering its own arrangement — the
    /// ordinary case — picks up the change immediately instead of waiting for
    /// its next navigation to notice.
    static let defaultPreferencesDidChange = Notification.Name("Nook.defaultPreferencesDidChange")

    private enum Key {
        static let defaultPreferences = "nook.defaultViewPreferences"
        static let homePreferences = "nook.homeViewPreferences"
        static let accentColorHex = "nook.accentColorHex"
        static let appearance = "nook.appearance"
        static let hiddenRevealTimeout = "nook.hiddenRevealTimeout"
        static let rehidesOnFocusLoss = "nook.rehidesOnFocusLoss"
        static let startPage = "nook.startPage"
        static let linkOpening = "nook.linkOpening"
        static let pinnedPlaces = "nook.pinnedPlaces"
        static let minimalMode = "nook.minimalMode"
    }

    private let defaults: UserDefaults
    /// Kept in the app group rather than `defaults`, because the quick save
    /// extension reads it from its own process.
    private let quickSave: QuickSaveSettings
    /// The look, mirrored for the share extensions.
    private let sharedAppearance: SharedAppearance

    var defaultPreferences: LocationViewPreferences {
        didSet {
            persist(defaultPreferences, forKey: Key.defaultPreferences)
            NotificationCenter.default.post(name: Self.defaultPreferencesDidChange, object: nil)
        }
    }

    /// What Home has been asked to remember, or nil while it is still
    /// following the global default.
    ///
    /// A folder keeps its own arrangement on the folder; Home is not a row in
    /// the library, so its arrangement is kept here instead. Nil rather than a
    /// value, so "remember this location" means the same thing on Home as it
    /// does anywhere else — off, and Home follows the default again.
    var homePreferences: LocationViewPreferences? {
        didSet {
            guard let homePreferences else {
                defaults.removeObject(forKey: Key.homePreferences)
                return
            }
            persist(homePreferences, forKey: Key.homePreferences)
        }
    }

    /// The global app tint. Entity colours stay identity markers and never
    /// retint the interface, so this is the only thing that does.
    var accentColorHex: String? {
        didSet {
            defaults.set(accentColorHex, forKey: Key.accentColorHex)
            sharedAppearance.accentColorHex = accentColorHex
        }
    }

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var hiddenRevealTimeout: HiddenRevealTimeout {
        didSet { defaults.set(hiddenRevealTimeout.rawValue, forKey: Key.hiddenRevealTimeout) }
    }

    var rehidesWhenAppLosesFocus: Bool {
        didSet { defaults.set(rehidesWhenAppLosesFocus, forKey: Key.rehidesOnFocusLoss) }
    }

    var startPage: StartPage {
        didSet { defaults.set(startPage.rawValue, forKey: Key.startPage) }
    }

    var linkOpening: LinkOpening {
        didSet { defaults.set(linkOpening.rawValue, forKey: Key.linkOpening) }
    }

    /// What sits in the sidebar's cards after the fixed four, in the order it
    /// was pinned. Never more than `PinnedPlace.limit`.
    private(set) var pinnedPlaces: [PinnedPlace] {
        didSet {
            guard let data = try? JSONEncoder().encode(pinnedPlaces) else { return }
            defaults.set(data, forKey: Key.pinnedPlaces)
        }
    }

    var canPinMore: Bool { pinnedPlaces.count < PinnedPlace.limit }

    func isPinned(_ place: PinnedPlace) -> Bool { pinnedPlaces.contains(place) }

    func pin(_ place: PinnedPlace) {
        guard canPinMore, !isPinned(place) else { return }
        pinnedPlaces.append(place)
    }

    func unpin(_ place: PinnedPlace) {
        pinnedPlaces.removeAll { $0 == place }
    }

    /// The folder the quick save extension saves into, or nil for the Inbox.
    var quickSaveFolderID: FolderID? {
        didSet { quickSave.folderID = quickSaveFolderID }
    }

    /// What opening a link actually does here. The Mac has no system in-app
    /// browser, so there a link always leaves for the default one.
    var effectiveLinkOpening: LinkOpening {
        #if os(iOS)
        linkOpening
        #else
        .defaultBrowser
        #endif
    }

    init(defaults: UserDefaults = .standard, sharedDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.quickSave = QuickSaveSettings(defaults: sharedDefaults)
        // Settings kept somewhere other than the standard defaults — a test's
        // own suite — keep their mirror there too, rather than writing over
        // what the real extensions read.
        self.sharedAppearance = SharedAppearance(defaults: sharedDefaults ?? (defaults == .standard ? nil : defaults))
        self.defaultPreferences = Self.load(from: defaults, key: Key.defaultPreferences)
            ?? .systemDefault
        self.homePreferences = Self.load(from: defaults, key: Key.homePreferences)
        self.accentColorHex = defaults.string(forKey: Key.accentColorHex)
        self.appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        self.hiddenRevealTimeout = defaults.string(forKey: Key.hiddenRevealTimeout)
            .flatMap(HiddenRevealTimeout.init(rawValue:)) ?? .after5Minutes
        self.rehidesWhenAppLosesFocus = defaults.object(forKey: Key.rehidesOnFocusLoss) == nil
            ? true
            : defaults.bool(forKey: Key.rehidesOnFocusLoss)
        self.startPage = defaults.string(forKey: Key.startPage)
            .flatMap(StartPage.init(rawValue:)) ?? .all
        self.linkOpening = defaults.string(forKey: Key.linkOpening)
            .flatMap(LinkOpening.init(rawValue:)) ?? .defaultBrowser
        self.quickSaveFolderID = quickSave.folderID
        self.isMinimalMode = defaults.bool(forKey: Key.minimalMode)
        self.pinnedPlaces = defaults.data(forKey: Key.pinnedPlaces)
            .flatMap { try? JSONDecoder().decode([PinnedPlace].self, from: $0) } ?? []
        // Brought up to date on every launch, so a look chosen before the
        // extensions could read it still reaches them.
        sharedAppearance.accentColorHex = accentColorHex
        sharedAppearance.isMinimalMode = isMinimalMode
    }

    /// The tint the interface takes. Minimal Mode sets it to plain black —
    /// white in dark mode, where black would vanish.
    var accentColor: Color? { isMinimalMode ? .primary : Color(hex: accentColorHex) }

    /// The accent as chosen, whatever Minimal Mode does to the interface.
    var chosenAccentColor: Color {
        if let color = Color(hex: accentColorHex) { return color }
        #if os(macOS)
        return Color(nsColor: .controlAccentColor)
        #else
        return .blue
        #endif
    }

    /// Strips Nook back to the system's own look: SF Symbols in place of the
    /// full-colour add icons, a black accent, and no tinted wash behind the
    /// canvas.
    var isMinimalMode: Bool {
        didSet {
            defaults.set(isMinimalMode, forKey: Key.minimalMode)
            sharedAppearance.isMinimalMode = isMinimalMode
        }
    }

    private func persist(_ value: LocationViewPreferences, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(from defaults: UserDefaults, key: String) -> LocationViewPreferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LocationViewPreferences.self, from: data)
    }
}

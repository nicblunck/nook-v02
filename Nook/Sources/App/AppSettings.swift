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
    }

    private let defaults: UserDefaults

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
        didSet { defaults.set(accentColorHex, forKey: Key.accentColorHex) }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
    }

    var accentColor: Color? { Color(hex: accentColorHex) }

    private func persist(_ value: LocationViewPreferences, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(from defaults: UserDefaults, key: String) -> LocationViewPreferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LocationViewPreferences.self, from: data)
    }
}

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
    private enum Key {
        static let defaultPreferences = "nook.defaultViewPreferences"
        static let homePreferences = "nook.homeViewPreferences"
        static let accentColorHex = "nook.accentColorHex"
        static let appearance = "nook.appearance"
    }

    private let defaults: UserDefaults

    var defaultPreferences: LocationViewPreferences {
        didSet { persist(defaultPreferences, forKey: Key.defaultPreferences) }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultPreferences = Self.load(from: defaults, key: Key.defaultPreferences)
            ?? .systemDefault
        self.homePreferences = Self.load(from: defaults, key: Key.homePreferences)
        self.accentColorHex = defaults.string(forKey: Key.accentColorHex)
        self.appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
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

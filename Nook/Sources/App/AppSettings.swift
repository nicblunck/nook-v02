import SwiftUI
import NookLibrary

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
        static let accentColorHex = "nook.accentColorHex"
    }

    private let defaults: UserDefaults

    var defaultPreferences: LocationViewPreferences {
        didSet { persist(defaultPreferences, forKey: Key.defaultPreferences) }
    }

    /// The global app tint. Entity colours stay identity markers and never
    /// retint the interface, so this is the only thing that does.
    var accentColorHex: String? {
        didSet { defaults.set(accentColorHex, forKey: Key.accentColorHex) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultPreferences = Self.load(from: defaults, key: Key.defaultPreferences)
            ?? .systemDefault
        self.accentColorHex = defaults.string(forKey: Key.accentColorHex)
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

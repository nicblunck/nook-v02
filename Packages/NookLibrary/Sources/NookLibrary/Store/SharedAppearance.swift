import Foundation

/// The look the app has been given — its accent colour and whether Minimal
/// Mode is on — copied into the app group so the share extensions, each in
/// their own process, dress themselves to match.
public struct SharedAppearance {
    static let accentKey = "nook.sharedAccentColorHex"
    static let minimalKey = "nook.sharedMinimalMode"

    private let defaults: UserDefaults

    /// The app group's defaults unless told otherwise, or the process's own
    /// when the group isn't usable, as in an unsigned development build.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: LibraryLocations.defaultAppGroupIdentifier)
            ?? .standard
    }

    /// `#RRGGBB`, or nil for the system accent.
    public var accentColorHex: String? {
        get { defaults.string(forKey: Self.accentKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.accentKey) }
    }

    public var isMinimalMode: Bool {
        get { defaults.bool(forKey: Self.minimalKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.minimalKey) }
    }
}

import Foundation

/// Where the quick save extension puts what it saves.
///
/// The app chooses it in Settings and the extension reads it, each in its own
/// process, so it lives in the app group's defaults rather than in either
/// one's own. No folder means the Inbox, which is also where a quick save goes
/// once its folder has been deleted.
public struct QuickSaveSettings {
    static let folderKey = "nook.quickSaveFolder"

    private let defaults: UserDefaults

    /// The app group's defaults unless told otherwise, or the process's own
    /// when the group isn't usable, as in an unsigned development build.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: LibraryLocations.defaultAppGroupIdentifier)
            ?? .standard
    }

    /// The folder quick saves land in, or nil for the Inbox.
    public var folderID: FolderID? {
        get {
            defaults.string(forKey: Self.folderKey).flatMap(FolderID.init(uuidString:))
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.uuid.uuidString, forKey: Self.folderKey)
            } else {
                defaults.removeObject(forKey: Self.folderKey)
            }
        }
    }
}

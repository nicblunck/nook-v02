import Foundation
import SwiftData

public extension LibraryService {

    /// What this location has been explicitly asked to remember, or nil when it
    /// has no opinion and should follow the global default.
    ///
    /// Only folders and collections can hold an opinion. System destinations —
    /// Inbox, Recent, Favorites, a media type — always follow the default, so
    /// there is no hidden state to explain when one of them looks different.
    func rememberedPreferences(for scope: LibraryScope) -> LocationViewPreferences? {
        switch scope {
        case .folder(let id), .folderTree(let id):
            LocationViewPreferences(encoded: folder(withIdentifier: id.uuid)?.rememberedPreferencesData)
        case .collection(let id):
            LocationViewPreferences(encoded: collection(withIdentifier: id.uuid)?.rememberedPreferencesData)
        default:
            nil
        }
    }

    func canRememberPreferences(for scope: LibraryScope) -> Bool {
        switch scope {
        case .folder, .folderTree, .collection: true
        default: false
        }
    }

    func rememberPreferences(_ preferences: LocationViewPreferences, for scope: LibraryScope) throws {
        try setRememberedPreferencesData(preferences.encoded, for: scope)
    }

    /// Drops a location's remembered settings; it goes back to following the
    /// global default the next time it is opened.
    func forgetPreferences(for scope: LibraryScope) throws {
        try setRememberedPreferencesData(nil, for: scope)
    }

    private func setRememberedPreferencesData(_ data: Data?, for scope: LibraryScope) throws {
        switch scope {
        case .folder(let id), .folderTree(let id):
            guard let target = folder(withIdentifier: id.uuid) else {
                throw LibraryError.folderNotFound(id)
            }
            target.rememberedPreferencesData = data
        case .collection(let id):
            guard let target = collection(withIdentifier: id.uuid) else {
                throw LibraryError.collectionNotFound(id)
            }
            target.rememberedPreferencesData = data
        default:
            return
        }
        try didMutate()
    }
}

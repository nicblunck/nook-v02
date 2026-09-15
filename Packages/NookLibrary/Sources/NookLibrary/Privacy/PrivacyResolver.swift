import Foundation

/// Resolves effective privacy by walking the true folder hierarchy.
///
/// Folder protection inherits downward and reaches descendants everywhere they
/// surface — including through collections and search — which is why this walks
/// ancestry rather than reading a single flag. Collection privacy is
/// deliberately *not* part of this: it protects the collection surface only,
/// and is applied where a collection is being browsed.
enum PrivacyResolver {
    static func effectivePrivacy(of object: LibraryObject) -> EffectivePrivacy {
        var flags = object.privacyFlags
        var hiddenSource: LibraryReference? = flags.isHidden ? object.reference : nil
        // Objects can never carry their own lock — only an ancestor folder
        // can lock an object, so `lockedSource` here can only ever be a
        // folder found while walking up, never the object itself.
        var lockedSource: LibraryReference?

        var current = object.folder
        var seen: Set<UUID> = []
        while let folder = current, !seen.contains(folder.identifier) {
            seen.insert(folder.identifier)
            if folder.isHidden, hiddenSource == nil || !flags.isHidden {
                if !flags.isHidden { hiddenSource = folder.reference }
                flags.isHidden = true
            }
            if folder.isLocked, !flags.isLocked {
                lockedSource = folder.reference
                flags.isLocked = true
            }
            current = folder.parent
        }

        return EffectivePrivacy(flags: flags, hiddenSource: hiddenSource, lockedSource: lockedSource,
                                 isLockedAtSource: false)
    }

    static func effectivePrivacy(of folder: Folder) -> EffectivePrivacy {
        var flags = folder.privacyFlags
        var hiddenSource: LibraryReference? = flags.isHidden ? folder.reference : nil
        var lockedSource: LibraryReference? = flags.isLocked ? folder.reference : nil

        for ancestor in folder.ancestors {
            if ancestor.isHidden, !flags.isHidden {
                hiddenSource = ancestor.reference
                flags.isHidden = true
            }
            if ancestor.isLocked, !flags.isLocked {
                lockedSource = ancestor.reference
                flags.isLocked = true
            }
        }

        // True only when the folder's own flag won the race above — i.e. no
        // ancestor got there first. That is exactly "this folder is itself
        // the locked door" rather than something buried behind one.
        let isLockedAtSource = flags.isLocked && lockedSource == folder.reference
        return EffectivePrivacy(flags: flags, hiddenSource: hiddenSource, lockedSource: lockedSource,
                                 isLockedAtSource: isLockedAtSource)
    }

    /// A collection's own surface privacy. Its members keep whatever privacy
    /// their folder ancestry gives them, independently of this. Collections
    /// cannot be locked, only hidden.
    static func surfacePrivacy(of collection: LibraryCollection) -> EffectivePrivacy {
        let flags = collection.privacyFlags
        return EffectivePrivacy(
            flags: flags,
            hiddenSource: flags.isHidden ? collection.reference : nil,
            lockedSource: nil,
            isLockedAtSource: false
        )
    }
}

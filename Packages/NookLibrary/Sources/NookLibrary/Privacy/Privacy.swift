import Foundation

/// The privacy flags an entity carries in its own right, before inheritance.
///
/// Hidden and Locked are independent: an entity may be neither, either, or both.
public struct PrivacyFlags: Hashable, Sendable, Codable {
    public var isHidden: Bool
    public var isLocked: Bool

    public static let normal = PrivacyFlags(isHidden: false, isLocked: false)

    public init(isHidden: Bool = false, isLocked: Bool = false) {
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    public var isProtected: Bool { isHidden || isLocked }

    /// Combines an entity's own flags with those inherited from its ancestry.
    /// Protection only ever accumulates downward; a child cannot opt out.
    public func union(_ other: PrivacyFlags) -> PrivacyFlags {
        PrivacyFlags(isHidden: isHidden || other.isHidden,
                     isLocked: isLocked || other.isLocked)
    }
}

/// Effective privacy after folder inheritance, together with the entity that
/// imposed each protection — needed so the UI can say *why* something is locked
/// and so authenticating that ancestor releases its descendants.
public struct EffectivePrivacy: Hashable, Sendable {
    public var flags: PrivacyFlags
    /// The entity whose Hidden state applies, if any. May be the entity itself.
    public var hiddenSource: LibraryReference?
    /// The entity whose Locked state applies, if any. May be the entity itself.
    public var lockedSource: LibraryReference?
    /// True when `lockedSource` is the entity itself rather than an ancestor
    /// folder — i.e. this entity *is* the locked door, not something buried
    /// behind one. Only a folder can ever be true here, since only folders
    /// carry their own lock flag; an object or collection's lock, when
    /// present, always comes from an ancestor.
    public var isLockedAtSource: Bool

    public static let normal = EffectivePrivacy(flags: .normal)

    public init(flags: PrivacyFlags,
                hiddenSource: LibraryReference? = nil,
                lockedSource: LibraryReference? = nil,
                isLockedAtSource: Bool = false) {
        self.flags = flags
        self.hiddenSource = hiddenSource
        self.lockedSource = lockedSource
        self.isLockedAtSource = isLockedAtSource
    }

    public var isHidden: Bool { flags.isHidden }
    public var isLocked: Bool { flags.isLocked }
}

/// The authenticated state a caller is operating under.
///
/// Constructed only by the authentication layer after a successful Face ID,
/// Touch ID or device-passcode check. The default grants nothing: consumers
/// that do not authenticate — search, Spotlight, Siri, MCP, model providers —
/// get `.standard` and therefore never see hidden content.
public struct AccessContext: Sendable {
    /// True while hidden items are revealed throughout the library.
    public var hiddenContextUnlocked: Bool
    /// Entities the user has authenticated against this session, by raw id.
    /// A folder here also releases everything beneath it.
    public var unlockedEntities: Set<UUID>

    /// The context every unauthenticated consumer gets.
    public static let standard = AccessContext(hiddenContextUnlocked: false, unlockedEntities: [])

    public init(hiddenContextUnlocked: Bool = false, unlockedEntities: Set<UUID> = []) {
        self.hiddenContextUnlocked = hiddenContextUnlocked
        self.unlockedEntities = unlockedEntities
    }

    public func unlocking(_ reference: LibraryReference) -> AccessContext {
        var copy = self
        copy.unlockedEntities.insert(reference.uuid)
        return copy
    }

    public func enteringHiddenContext() -> AccessContext {
        var copy = self
        copy.hiddenContextUnlocked = true
        return copy
    }

    /// The same context with hidden content out of reach again.
    ///
    /// Unlocked folders are untouched here — leaving Hidden and leaving a
    /// locked folder are different events. A locked folder re-locks when the
    /// browsed location steps outside its subtree, which the app layer
    /// tracks separately by pruning `unlockedEntities` on navigation.
    public func leavingHiddenContext() -> AccessContext {
        var copy = self
        copy.hiddenContextUnlocked = false
        return copy
    }
}

/// What a caller is permitted to see of an entity.
public enum Visibility: Hashable, Sendable {
    /// Fully readable, including contents and originals.
    case full
    /// The locked door itself: a folder that is explicitly locked may still
    /// appear structurally (name, icon, badge) wherever it would otherwise be
    /// listed, but its thumbnails, previews, contents and sensitive metadata
    /// are withheld until the lock is authenticated. Only a folder that
    /// carries its own lock flag ever resolves here — an object or
    /// collection made visible only by an ancestor's lock is `.excluded`.
    case redacted(lockedBy: LibraryReference?)
    /// Must not appear at all: not in browsing, search, Spotlight, Siri,
    /// widgets, MCP or model context. This is also what anything buried
    /// inside a locked folder resolves to, everywhere except while browsing
    /// inside that folder's own subtree while authenticated.
    case excluded

    public var isExcluded: Bool {
        if case .excluded = self { return true }
        return false
    }

    public var isRedacted: Bool {
        if case .redacted = self { return true }
        return false
    }
}

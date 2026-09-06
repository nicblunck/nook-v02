import Foundation

/// The single point at which privacy is decided.
///
/// Every consumer — the UI, metadata search, App Intents, Spotlight, the MCP
/// adapter, model providers — resolves visibility here. Nothing above this
/// layer re-implements the rules, so no integration can arrive at a more
/// permissive answer than the UI would, and an instruction to a model cannot
/// talk its way past a lock.
///
/// The broker is deliberately a pure function of (effective privacy, access
/// context). It performs no I/O and holds no state, which is what makes it
/// cheap enough to apply to every row of every query.
public struct PrivacyBroker: Sendable {
    public init() {}

    /// Resolves what a caller may see. Defaults to denial: anything whose
    /// privacy could not be established is treated as protected.
    public func visibility(of privacy: EffectivePrivacy, in context: AccessContext) -> Visibility {
        if privacy.isHidden && !isReleased(privacy.hiddenSource, in: context, requiresHiddenContext: true) {
            return .excluded
        }
        if privacy.isLocked && !isReleased(privacy.lockedSource, in: context, requiresHiddenContext: false) {
            return .redacted(lockedBy: privacy.lockedSource)
        }
        return .full
    }

    /// Whether a protected item may be listed at all.
    public func allowsDiscovery(of privacy: EffectivePrivacy, in context: AccessContext) -> Bool {
        !visibility(of: privacy, in: context).isExcluded
    }

    /// Whether contents — original bytes, extracted text, thumbnails, previews —
    /// may be produced. Redaction withholds content while permitting the row.
    public func allowsContent(of privacy: EffectivePrivacy, in context: AccessContext) -> Bool {
        visibility(of: privacy, in: context) == .full
    }

    private func isReleased(_ source: LibraryReference?,
                            in context: AccessContext,
                            requiresHiddenContext: Bool) -> Bool {
        if requiresHiddenContext && context.hiddenContextUnlocked { return true }
        guard let source else { return false }
        return context.unlockedEntities.contains(source.uuid)
    }
}

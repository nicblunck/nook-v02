import Foundation

/// What a model is being asked to do.
///
/// Provider-neutral on purpose: no vendor's message, role or tool types appear
/// here, so swapping providers does not reach back into the library.
public struct IntelligenceRequest: Sendable {
    /// What the user asked, in their own words.
    public var instruction: String
    /// The items the question is about, if it is about particular ones.
    public var subjects: [LibraryReference]
    /// Whether the provider may call the tool surface to find things itself.
    public var allowsLibraryLookup: Bool

    public init(instruction: String,
                subjects: [LibraryReference] = [],
                allowsLibraryLookup: Bool = true) {
        self.instruction = instruction
        self.subjects = subjects
        self.allowsLibraryLookup = allowsLibraryLookup
    }
}

public struct IntelligenceResponse: Sendable {
    public var text: String
    /// What the answer drew on, so it can be shown alongside the answer.
    public var citations: [LibraryReference]

    public init(text: String, citations: [LibraryReference] = []) {
        self.text = text
        self.citations = citations
    }
}

public enum IntelligenceError: Error, Sendable, LocalizedError {
    case providerUnavailable(String)
    case noProviderConfigured
    case refused(reason: String)

    public var errorDescription: String? {
        switch self {
        case .providerUnavailable(let name): "\(name) isn't available right now."
        case .noProviderConfigured: "No intelligence provider is turned on."
        case .refused(let reason): reason
        }
    }
}

/// A source of answers.
///
/// Apple's on-device models, Claude, OpenAI and whatever comes next all sit
/// behind this. None of them is privileged: the library keeps tool definitions,
/// privacy decisions and content selection on its own side of the line, and a
/// provider only ever sees what the tool surface hands it — which has already
/// been through the privacy broker.
public protocol IntelligenceProvider: Sendable {
    /// Stable identifier, used to remember which provider the user chose.
    var identifier: String { get }
    var displayName: String { get }

    /// Whether this provider can be used right now — the model is downloaded,
    /// the account is configured, the device supports it.
    var isAvailable: Bool { get async }

    /// Whether using it sends library content off the device. The user is
    /// entitled to know that before choosing, so it is part of the contract
    /// rather than a note in a settings screen.
    var processesContentRemotely: Bool { get }

    func respond(
        to request: IntelligenceRequest,
        using surface: LibraryToolSurface
    ) async throws -> IntelligenceResponse
}

/// Routes a request to the chosen provider.
///
/// Holds the provider the user picked and nothing else. It exists so the rest
/// of the app never names a vendor, and so the user can turn any provider off
/// independently of the others.
public actor IntelligenceSession {
    private var providers: [any IntelligenceProvider]
    private var selectedIdentifier: String?

    public init(providers: [any IntelligenceProvider] = [], selectedIdentifier: String? = nil) {
        self.providers = providers
        self.selectedIdentifier = selectedIdentifier ?? providers.first?.identifier
    }

    public func register(_ provider: any IntelligenceProvider) {
        providers.removeAll { $0.identifier == provider.identifier }
        providers.append(provider)
        if selectedIdentifier == nil { selectedIdentifier = provider.identifier }
    }

    public func remove(identifier: String) {
        providers.removeAll { $0.identifier == identifier }
        if selectedIdentifier == identifier { selectedIdentifier = providers.first?.identifier }
    }

    public func select(identifier: String?) {
        selectedIdentifier = identifier
    }

    public var availableProviders: [(identifier: String, displayName: String, processesContentRemotely: Bool)] {
        get async {
            var result: [(String, String, Bool)] = []
            for provider in providers where await provider.isAvailable {
                result.append((provider.identifier, provider.displayName, provider.processesContentRemotely))
            }
            return result
        }
    }

    public func respond(
        to request: IntelligenceRequest,
        using surface: LibraryToolSurface
    ) async throws -> IntelligenceResponse {
        guard let identifier = selectedIdentifier,
              let provider = providers.first(where: { $0.identifier == identifier })
        else {
            throw IntelligenceError.noProviderConfigured
        }
        guard await provider.isAvailable else {
            throw IntelligenceError.providerUnavailable(provider.displayName)
        }
        return try await provider.respond(to: request, using: surface)
    }
}

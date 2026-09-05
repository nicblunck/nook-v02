import Foundation

/// The one library instance a process uses.
///
/// The app, an App Intent and the share extension can each be the first thing
/// to need the library, and each may run when the others are not. They all
/// come through here so a process never ends up with two model containers over
/// one store.
public actor SharedLibrary {
    public static let shared = SharedLibrary()

    private var library: Library?
    private var bootstrapTask: Task<Library, any Error>?

    private init() {}

    /// Opens the library, or returns the one already open. Concurrent callers
    /// await the same bootstrap rather than racing to open the store twice.
    public func current(
        locations: LibraryLocations? = nil,
        syncMode: LibrarySyncMode = .local
    ) async throws -> Library {
        if let library { return library }
        if let bootstrapTask { return try await bootstrapTask.value }

        let task = Task<Library, any Error> {
            let resolved = try locations ?? LibraryLocations.shared()
            return try await Library.bootstrap(locations: resolved, syncMode: syncMode)
        }
        bootstrapTask = task

        do {
            let opened = try await task.value
            library = opened
            bootstrapTask = nil
            return opened
        } catch {
            bootstrapTask = nil
            throw error
        }
    }
}

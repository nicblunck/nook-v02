import Foundation
import Testing
@testable import NookLibrary

@Suite("Library locations")
struct LibraryLocationsTests {
    @Test("An unwritable app-group URL falls back to application storage")
    func unwritableGroupFallsBack() throws {
        let scratch = URL.temporaryDirectory
            .appending(path: "NookLocationsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        // A regular file cannot contain the requested Library directory. This
        // deterministically models containerURL returning an unusable URL.
        let unusableContainer = scratch.appending(path: "NotADirectory")
        try Data().write(to: unusableContainer)
        let fallback = LibraryLocations(root: scratch.appending(path: "Fallback"))

        let resolved = try LibraryLocations.resolveShared(
            appGroupIdentifier: "group.test.nook",
            groupContainer: { _ in unusableContainer },
            fallback: { fallback }
        )

        #expect(resolved.root == fallback.root)
    }

    @Test("A writable app-group URL remains the shared location")
    func writableGroupIsUsed() throws {
        let container = URL.temporaryDirectory
            .appending(path: "NookLocationsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let resolved = try LibraryLocations.resolveShared(
            appGroupIdentifier: "group.test.nook",
            groupContainer: { _ in container },
            fallback: { LibraryLocations(root: container.appending(path: "Fallback")) }
        )

        #expect(resolved.root == container.appending(path: "Library"))
    }
}

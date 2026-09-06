import Foundation
import Testing
@testable import NookLibrary

/// A throwaway library plus a scratch directory for source files, so each test
/// starts from nothing and leaves nothing behind.
struct TestLibrary {
    let library: Library
    let scratch: URL

    init() async throws {
        library = try await Library.inMemory()
        scratch = URL.temporaryDirectory.appending(path: "NookTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    var service: LibraryService { library.service }

    /// Writes a file outside the library, to be imported.
    func makeSourceFile(named name: String, contents: String) throws -> URL {
        let url = scratch.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: scratch)
    }
}

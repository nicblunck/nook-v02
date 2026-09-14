import Foundation
import UniformTypeIdentifiers
import NookLibrary
@testable import Nook

/// A model over a throwaway library, with defaults of its own so one test's
/// remembered view preferences never reach the next one — or the real app.
@MainActor
struct TestModel {
    let model: LibraryModel
    let scratch: URL
    private let suiteName: String

    init() async throws {
        let suiteName = "nook.tests.\(UUID().uuidString)"
        self.suiteName = suiteName
        let library = try await Library.inMemory()
        model = LibraryModel(
            library: library,
            settings: AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        )
        scratch = URL.temporaryDirectory.appending(path: "NookAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    /// Imports a file into wherever the model is currently pointing.
    ///
    /// `as` declares the content type rather than leaving it to be read off
    /// the file, so a test can make an image without carrying real pixels.
    @discardableResult
    func importFile(named name: String,
                    contents: String = "hello",
                    as contentType: UTType? = nil) async throws -> ObjectSnapshot? {
        let url = scratch.appending(path: name)
        try Data(contents.utf8).write(to: url)
        await model.importItems([.file(url: url, contentType: contentType)])
        return model.contents.objects.first { $0.originalFilename == name }
    }

    func makeDirectory(named name: String) throws -> URL {
        let url = scratch.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: scratch)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

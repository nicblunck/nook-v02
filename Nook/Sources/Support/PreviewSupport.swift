#if DEBUG
import SwiftUI
import NookLibrary

/// A seeded, throwaway library for Xcode's canvas.
///
/// `Library.inMemory()` and importing sample items are both async, but a
/// `#Preview` body is not, so `PreviewHost` bridges the two: it shows a
/// spinner until `PreviewLibrary.makeModel()` finishes, then hands the ready
/// model to its content closure.
@MainActor
enum PreviewLibrary {
    static func makeModel() async -> LibraryModel {
        guard let library = try? await Library.inMemory() else {
            fatalError("PreviewLibrary couldn't create an in-memory library")
        }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "nook.preview.\(UUID().uuidString)")!)
        let model = LibraryModel(library: library, settings: settings, authenticator: PreviewAuthenticator())
        await seed(model)
        return model
    }

    private static func seed(_ model: LibraryModel) async {
        await model.createFolder(named: "Photos", in: nil)
        await model.createFolder(named: "Recipes", in: nil)

        let scratch = URL.temporaryDirectory.appending(path: "NookPreview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        func file(_ name: String, _ text: String) -> URL {
            let url = scratch.appending(path: name)
            try? Data(text.utf8).write(to: url)
            return url
        }

        let ids = await model.importItems([
            .file(url: file("Trip Notes.txt", "Notes from the coast trip.")),
            .file(url: file("Focaccia Recipe.txt", "Olive oil, flour, salt, time.")),
            .file(url: file("Reading List.txt", "Books to read this year."))
        ])
        if let first = ids.first {
            await model.setFavorite(true, for: [first])
            await model.addTag("Inspiration", to: [first])
            model.selection = [first]
        }
    }
}

/// Always succeeds, so a preview never sits behind a Face ID prompt.
@MainActor
private final class PreviewAuthenticator: LibraryAuthenticating {
    func authenticate(reason: String) async -> AuthenticationOutcome { .succeeded }
}

/// Waits for a seeded `PreviewLibrary` model, then builds `content` from it.
struct PreviewHost<Content: View>: View {
    @State private var model: LibraryModel?
    private let content: (LibraryModel) -> Content

    init(@ViewBuilder content: @escaping (LibraryModel) -> Content) {
        self.content = content
    }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            model = await PreviewLibrary.makeModel()
        }
    }
}
#endif

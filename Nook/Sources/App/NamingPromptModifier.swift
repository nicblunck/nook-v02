import SwiftUI
import NookLibrary

/// Presents the lightweight rename prompts. Creation uses the shared
/// appearance editor so a new place is named and styled in one pass.
///
/// Attached once at the window rather than in the sidebar, because the same
/// prompts are raised from the menu bar and from iPhone, where there is no
/// sidebar to raise them from.
struct NamingPromptModifier: ViewModifier {
    @Bindable var model: LibraryModel
    @State private var draftName = ""

    func body(content: Content) -> some View {
        content
            .alert(model.namingPrompt?.title ?? "", isPresented: isPresented) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) {}
                Button(model.namingPrompt?.confirmTitle ?? "Save") { commit() }
            } message: {
                if let message = model.namingPrompt?.message { Text(message) }
            }
            .onChange(of: model.namingPrompt?.id) {
                draftName = model.namingPrompt.map(initialName) ?? ""
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { model.namingPrompt != nil },
                set: { if !$0 { model.namingPrompt = nil } })
    }

    /// Seeds the field from the prompt rather than from whoever opened it, so
    /// a rename raised from the menu bar arrives filled in too.
    private func initialName(for prompt: NamingPrompt) -> String {
        switch prompt {
        case .renameFolder(let id):
            model.allFolders.first { $0.folder.id == id }?.folder.name ?? ""
        case .renameCollection(let id):
            model.collections.first { $0.id == id }?.name ?? ""
        case .renameTag(let id):
            model.tags.first { $0.id == id }?.name ?? ""
        }
    }

    private func commit() {
        guard let prompt = model.namingPrompt else { return }
        let name = draftName
        Task {
            switch prompt {
            case .renameFolder(let id): await model.rename(folder: id, to: name)
            case .renameCollection(let id): await model.renameCollection(id, to: name)
            case .renameTag(let id): await model.renameTag(id, to: name)
            }
        }
    }
}

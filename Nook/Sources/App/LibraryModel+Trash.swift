import SwiftUI
import NookLibrary

/// What is about to go to the Trash, or out of it for good, waiting on the
/// person to say yes.
///
/// Every way of throwing something away — a menu, the sidebar, the Delete key,
/// the Empty Trash button — asks through this one request, so the question is
/// worded the same wherever it was asked from.
enum TrashRequest: Identifiable, Equatable {
    case moveToTrash(TrashItems)
    case deleteImmediately(TrashItems)
    case emptyTrash

    var id: String {
        switch self {
        case .moveToTrash(let items): "move-\(items.id)"
        case .deleteImmediately(let items): "delete-\(items.id)"
        case .emptyTrash: "empty"
        }
    }

    var title: String {
        switch self {
        case .moveToTrash(let items):
            if let name = items.singleName { return String(localized: "Move “\(name)” to Trash?") }
            return String(localized: "Move \(items.count) items to Trash?")
        case .deleteImmediately(let items):
            if let name = items.singleName { return String(localized: "Delete “\(name)” Immediately?") }
            return String(localized: "Delete \(items.count) Items Immediately?")
        case .emptyTrash:
            return String(localized: "Empty Trash?")
        }
    }

    /// Only a deletion that cannot be undone has anything to add.
    var message: String? {
        switch self {
        case .moveToTrash: nil
        case .deleteImmediately, .emptyTrash: String(localized: "Deleted items cannot be recovered.")
        }
    }

    var confirmTitle: String {
        switch self {
        case .moveToTrash: String(localized: "Move to Trash")
        case .deleteImmediately: String(localized: "Delete")
        case .emptyTrash: String(localized: "Empty Trash")
        }
    }
}

/// The things one request is about. Folders and objects can go together: the
/// Delete key acts on whatever the canvas has chosen.
struct TrashItems: Equatable {
    var objects: [ObjectID] = []
    var folders: [FolderID] = []
    /// What to call the one thing, when there is only one.
    var singleName: String?

    var count: Int { objects.count + folders.count }
    var isEmpty: Bool { count == 0 }

    var id: String {
        (folders.map(\.uuid.uuidString) + objects.map(\.uuid.uuidString)).joined(separator: ",")
    }

    init(objects: [ObjectSnapshot] = [], folders: [FolderSnapshot] = []) {
        self.objects = objects.map(\.id)
        self.folders = folders.map(\.id)
        if objects.count + folders.count == 1 {
            singleName = objects.first?.title ?? folders.first?.name
        }
    }
}

@MainActor
extension LibraryModel {

    /// At the top of the Trash, where Empty Trash belongs.
    var isShowingTrash: Bool { !isShowingHome && scope == .trash }

    var canEmptyTrash: Bool { (counts[.trash] ?? 0) > 0 }

    // MARK: Asking

    func requestMoveToTrash(_ objects: [ObjectSnapshot]) {
        request(.moveToTrash(TrashItems(objects: objects)))
    }

    func requestMoveToTrash(_ folder: FolderSnapshot) {
        request(.moveToTrash(TrashItems(folders: [folder])))
    }

    func requestDeleteImmediately(_ objects: [ObjectSnapshot]) {
        request(.deleteImmediately(TrashItems(objects: objects)))
    }

    func requestDeleteImmediately(_ folder: FolderSnapshot) {
        request(.deleteImmediately(TrashItems(folders: [folder])))
    }

    func requestEmptyTrash() {
        guard canEmptyTrash else { return }
        trashRequest = .emptyTrash
    }

    /// The Delete key: whatever is open or chosen goes to the Trash — or, if
    /// it is in the Trash already, out of it for good. Either way it asks
    /// first. Returns whether there was anything to act on.
    @discardableResult
    func requestTrashForKeyboard() -> Bool {
        guard trashRequest == nil else { return false }
        let objects: [ObjectSnapshot]
        let folders: [FolderSnapshot]
        if let previewed = previewedObject {
            objects = [previewed]
            folders = []
        } else if !selectedObjects.isEmpty {
            objects = selectedObjects
            folders = []
        } else if let folder = cursorFolder {
            objects = []
            folders = [folder]
        } else {
            return false
        }
        let items = TrashItems(objects: objects, folders: folders)
        let inTrash = objects.allSatisfy(\.isInTrash) && folders.allSatisfy(\.isInTrash)
        request(inTrash ? .deleteImmediately(items) : .moveToTrash(items))
        return true
    }

    private func request(_ request: TrashRequest) {
        switch request {
        case .moveToTrash(let items), .deleteImmediately(let items):
            guard !items.isEmpty else { return }
        case .emptyTrash:
            break
        }
        trashRequest = request
    }

    // MARK: Answering

    func confirm(_ request: TrashRequest) async {
        if trashRequest == request { trashRequest = nil }
        switch request {
        case .moveToTrash(let items):
            for folder in items.folders { await moveFolderToTrash(folder) }
            await moveToTrash(items.objects)
        case .deleteImmediately(let items):
            for folder in items.folders { await deleteFolderImmediately(folder) }
            await permanentlyDelete(items.objects)
        case .emptyTrash:
            await emptyTrash()
        }
    }
}

/// Puts the question up. Attached once at the window, beside the naming
/// prompt, because it is raised from the menu bar, the sidebar and the canvas
/// alike.
struct TrashConfirmationModifier: ViewModifier {
    @Bindable var model: LibraryModel

    func body(content: Content) -> some View {
        content
            .alert(model.trashRequest?.title ?? "", isPresented: isPresented,
                   presenting: model.trashRequest) { request in
                Button("Cancel", role: .cancel) {}
                Button(request.confirmTitle, role: .destructive) {
                    Task { await model.confirm(request) }
                }
            } message: { request in
                if let message = request.message { Text(message) }
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { model.trashRequest != nil },
                set: { if !$0 { model.trashRequest = nil } })
    }
}

import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

/// Choose where it goes, then save it.
///
/// The destination picker is the point of the sheet: import is context-aware
/// everywhere else in the app, and the share sheet is the one place with no
/// context to infer, so it asks.
struct ShareView: View {
    let providers: [NSItemProvider]
    let onFinish: () -> Void
    let onCancel: () -> Void

    @State private var folders: [(folder: FolderSnapshot, depth: Int)] = []
    @State private var destination: FolderID?
    @State private var state: SaveState = .ready
    @State private var itemNames: [String] = []

    private enum SaveState: Equatable {
        case ready
        case saving
        case saved(Int)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Saving") {
                    if itemNames.isEmpty {
                        Text("Preparing…").foregroundStyle(.secondary)
                    } else {
                        ForEach(itemNames, id: \.self) { name in
                            Label(name, systemImage: "doc")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Section("Destination") {
                    Picker("Folder", selection: $destination) {
                        Label("Inbox", systemImage: "tray").tag(FolderID?.none)
                        ForEach(folders, id: \.folder.id) { entry in
                            Text(String(repeating: "   ", count: entry.depth) + entry.folder.name)
                                .tag(FolderID?.some(entry.folder.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if case .failed(let message) = state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Save to Nook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(state == .saving || itemNames.isEmpty)
                }
            }
            .overlay {
                if state == .saving {
                    ProgressView("Saving…")
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
        }
        .task { await load() }
    }

    // MARK: Loading

    private func load() async {
        itemNames = providers.map { $0.suggestedName ?? "Item" }
        guard let service = try? await SharedLibrary.shared.current().service else { return }

        var flattened: [(FolderSnapshot, Int)] = []
        var queue: [(FolderSnapshot, Int)] = await service.rootFolders().map { ($0, 0) }
        while !queue.isEmpty {
            let (folder, depth) = queue.removeFirst()
            flattened.append((folder, depth))
            let children = await service.subfolders(of: folder.id).map { ($0, depth + 1) }
            queue.insert(contentsOf: children, at: 0)
        }
        folders = flattened
    }

    // MARK: Saving

    private func save() async {
        state = .saving
        do {
            let library = try await SharedLibrary.shared.current()
            let items = await resolveItems()
            guard !items.isEmpty else {
                state = .failed("Nothing here could be saved.")
                return
            }

            let report = await library.service.importItems(
                items,
                into: destination.map(ImportDestination.folder) ?? .root
            )
            if report.hasFailures, report.importedIDs.isEmpty {
                state = .failed("Couldn't save these items.")
                return
            }
            state = .saved(report.importedIDs.count)
            onFinish()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Turns the share sheet's providers into import items. A URL becomes a
    /// link object; anything file-backed is copied in.
    @MainActor
    private func resolveItems() async -> [ImportItem] {
        var items: [ImportItem] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadWebURL(), !url.isFileURL {
                items.append(.link(url))
                continue
            }
            if let url = try? await provider.loadFileRepresentation(for: .item) {
                items.append(.file(url: url, contentType: nil))
            }
        }
        return items
    }
}

/// NSItemProvider is not Sendable, so these stay on the main actor with the
/// view that owns them; only the resulting URLs cross back.
@MainActor
private extension NSItemProvider {
    /// The loaded item is unwrapped inside the handler so only a URL — which
    /// is Sendable — travels back to the caller.
    func loadWebURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.url.identifier) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: item as? URL)
            }
        }
    }

    /// Copies the provided file somewhere the import can read it: the URL the
    /// system hands over is only valid inside the completion handler.
    func loadFileRepresentation(for type: UTType) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let destination = URL.temporaryDirectory
                    .appending(path: UUID().uuidString)
                    .appending(path: url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

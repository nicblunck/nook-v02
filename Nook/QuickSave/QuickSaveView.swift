import SwiftUI
import NookLibrary

/// Saves what was shared straight into the library, with nothing to fill in:
/// no title to check, no folder to pick, no tags. It lands where Settings says
/// quick saves go, which is the Inbox unless the user chose a folder.
///
/// The sheet only reports. It shows the save happening, then where it went,
/// then closes on its own. Only a failure waits for the user to close it.
struct QuickSaveView: View {
    let attachments: [SharedAttachment]
    let onFinish: () -> Void

    @State private var state: SaveState = .saving

    private enum SaveState: Equatable {
        case saving
        case saved(count: Int, destination: String)
        case failed(String)
    }

    /// Long enough to read where things went, short enough not to wait on.
    private static let confirmationDuration: Duration = .milliseconds(900)

    var body: some View {
        VStack(spacing: 14) {
            symbol
                .font(.system(size: 44))
                .frame(height: 52)

            Text(headline)
                .font(.headline)
                .multilineTextAlignment(.center)

            if case .failed(let message) = state {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Close", action: onFinish)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 6)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .combine)
        .task { await save() }
    }

    @ViewBuilder
    private var symbol: some View {
        switch state {
        case .saving:
            ProgressView()
                .controlSize(.large)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var headline: String {
        switch state {
        case .saving:
            "Saving…"
        case .saved(let count, let destination):
            count == 1 ? "Saved to \(destination)" : "Saved \(count) items to \(destination)"
        case .failed:
            "Couldn’t save to Nook"
        }
    }

    // MARK: Saving

    private func save() async {
        let library: Library
        do {
            library = try await SharedLibrary.shared.current()
        } catch {
            state = .failed("Nook’s library couldn’t be opened.")
            return
        }

        let items = await buildItems()
        defer {
            for item in items { item.resolved.removeTemporaryFiles() }
        }
        guard !items.isEmpty else {
            state = .failed("Nothing here could be saved.")
            return
        }

        // A folder deleted since it was chosen sends things to the Inbox
        // rather than failing the save.
        var destination = ImportDestination.root
        var destinationName = "Inbox"
        if let folderID = QuickSaveSettings().folderID,
           let folder = await library.service.folder(folderID) {
            destination = .folder(folderID)
            destinationName = folder.name
        }

        let report = await library.service.importItems(
            items.map(\.resolved.importItem),
            into: destination
        )

        var importedIDs: [ObjectID] = []
        for (index, result) in report.results.enumerated() {
            guard let objectID = result.objectID else { continue }
            importedIDs.append(objectID)

            // The same title the full sheet would have suggested, so a quick
            // save reads the same as one saved without edits.
            let title = items[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                try? await library.service.updateObject(objectID, title: title, notes: nil)
            }

            if let linkMetadata = items[index].linkMetadata {
                try? await library.service.applyLinkMetadata(linkMetadata.metadata, to: objectID)
                if let imageData = linkMetadata.previewImageData {
                    await library.thumbnails.storePreviewImage(imageData, for: objectID)
                }
            }
        }

        guard !importedIDs.isEmpty else {
            state = .failed("Nook couldn’t save these items.")
            return
        }

        // Made before the sheet goes away, while the originals are certainly
        // on this device, so other devices have a picture to show before the
        // originals themselves finish syncing.
        for objectID in importedIDs {
            _ = try? await library.service.generateSyncedThumbnail(
                for: objectID,
                using: library.thumbnails
            )
        }

        state = .saved(count: importedIDs.count, destination: destinationName)
        try? await Task.sleep(for: Self.confirmationDuration)
        onFinish()
    }

    /// Resolves the attachments the way the full sheet does, so one thing
    /// shared as several attachments is still saved once.
    private func buildItems() async -> [SharePreviewItem] {
        var resolved: [ResolvedShareItem] = []
        var sources: [SharedAttachment] = []
        for attachment in attachments {
            guard let item = await ShareItemResolver.resolve(attachment.provider) else { continue }
            resolved.append(item)
            sources.append(attachment)
        }

        var result: [SharePreviewItem] = []
        for (index, item) in ShareItemResolver.merged(resolved) {
            let attachment = sources[index]
            result.append(
                await SharePreview.makeItem(
                    id: index,
                    resolved: item,
                    fallbackName: ShareItemResolver.displayName(for: attachment.provider),
                    attachedMetadata: await LinkMetadataFetcher.attachedMetadataData(from: attachment.provider),
                    sharedTitle: attachment.sharedTitle
                )
            )
        }
        return result
    }
}

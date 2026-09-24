import SwiftUI
import NookLibrary

/// Review what is being shared, choose where it belongs, then save it.
struct MacShareView: View {
    let attachments: [SharedAttachment]
    let onFinish: () -> Void
    let onCancel: () -> Void

    @State private var items: [SharePreviewItem] = []
    @State private var isLoading = true

    @State private var folders: [(folder: FolderSnapshot, depth: Int)] = []
    @State private var destination: SaveDestination = .inbox

    @State private var collections: [CollectionSnapshot] = []
    @State private var collectionID: CollectionID?

    @State private var tags: [String] = []
    @State private var tagDraft = ""
    @State private var existingTags: [TagSnapshot] = []
    @State private var isTagsExpanded = false

    @State private var state: SaveState = .ready
    @FocusState private var isTagFieldFocused: Bool

    private enum SaveState: Equatable {
        case ready
        case saving
        case failed(String)
    }

    /// Where saved items go. Hidden sits alongside ordinary folders here even
    /// though it isn't one — it clears the item's folder and marks it hidden
    /// once import succeeds, the same way hiding something already in the
    /// library does.
    private enum SaveDestination: Hashable {
        case inbox
        case folder(FolderID)
        case hidden
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if case .failed(let message) = state {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    previews
                    itemDetails
                    saveToSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .background(.background)
        .overlay {
            if state == .saving {
                ProgressView("Saving…")
                    .padding(20)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        // The sheet's size is set once, by ShareViewController. A minimum here
        // larger than that sheet pushes the header and bottom margin out of view.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
    }

    // MARK: Header

    /// A close on the left, a checkmark on the right: the two ways out of the
    /// sheet, always in reach and never dependent on window chrome the
    /// extension's own presentation may or may not draw around it.
    private var header: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel")

            Spacer()

            Text("Save to Nook")
                .font(.headline)

            Spacer()

            Button { Task { await save() } } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(Color.blue)
            .keyboardShortcut(.defaultAction)
            .disabled(state == .saving || items.isEmpty)
            .opacity(items.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Save")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: Item details

    @ViewBuilder
    private var itemDetails: some View {
        if isLoading {
            RoundedRectangle(cornerRadius: 20)
                .fill(.quaternary.opacity(0.5))
                .frame(height: 174)
                .overlay { ProgressView() }
        } else if items.isEmpty {
            Label("Nothing here could be saved.", systemImage: "questionmark.folder")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(spacing: 12) {
                ForEach($items) { $item in
                    ShareItemDetailsCard(item: $item)
                }
            }
        }
    }

    // MARK: Save to

    private var saveToSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Save to")

            VStack(spacing: 0) {
                Menu {
                    Button { destination = .inbox } label: {
                        Label("Inbox", systemImage: "tray")
                    }
                    ForEach(folders, id: \.folder.id) { entry in
                        Button {
                            destination = .folder(entry.folder.id)
                        } label: {
                            Text(String(repeating: "  ", count: entry.depth) + entry.folder.name)
                        }
                    }
                    Divider()
                    Button { destination = .hidden } label: {
                        Label("Hidden", systemImage: "eye.slash")
                    }
                } label: {
                    DestinationRow(systemImage: destinationSystemImage, title: "Folder", value: destinationName)
                }
                .buttonStyle(.plain)

                ShareDivider()

                Menu {
                    Button { collectionID = nil } label: {
                        Text("None")
                    }
                    ForEach(collections) { collection in
                        Button {
                            collectionID = collection.id
                        } label: {
                            Text(collection.name)
                        }
                    }
                } label: {
                    DestinationRow(systemImage: "rectangle.stack", title: "Collection", value: collectionName)
                }
                .buttonStyle(.plain)

                ShareDivider()

                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        isTagsExpanded.toggle()
                    }
                } label: {
                    DestinationRow(
                        systemImage: "tag",
                        title: "Tags",
                        value: tags.isEmpty ? "None" : "\(tags.count)",
                        isExpanded: isTagsExpanded
                    )
                }
                .buttonStyle(.plain)
            }
            .background(.regularMaterial, in: .rect(cornerRadius: 20))

            if isTagsExpanded {
                tagsEditor
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var destinationName: String {
        switch destination {
        case .inbox: "Inbox"
        case .folder(let id): folders.first(where: { $0.folder.id == id })?.folder.name ?? "Inbox"
        case .hidden: "Hidden"
        }
    }

    private var destinationSystemImage: String {
        destination == .hidden ? "eye.slash" : "folder"
    }

    /// Hidden isn't a folder to import into — the item lands in the root and
    /// `setHidden` detaches it from there once the import succeeds.
    private var importDestination: ImportDestination {
        switch destination {
        case .inbox, .hidden: .root
        case .folder(let id): .folder(id)
        }
    }

    private var collectionName: String {
        guard let collectionID else { return "None" }
        return collections.first(where: { $0.id == collectionID })?.name ?? "None"
    }

    // MARK: Tags

    private var tagsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !tags.isEmpty {
                ShareTagFlow(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        ShareTagPill(name: tag, color: .accentColor) {
                            tags.removeAll { $0 == tag }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tertiary)
                TextField("Add a tag", text: $tagDraft)
                    .textFieldStyle(.plain)
                    .focused($isTagFieldFocused)
                    .onSubmit(addDraftTag)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            if !tagSuggestions.isEmpty {
                ShareTagFlow(spacing: 6) {
                    ForEach(tagSuggestions) { suggestion in
                        Button { addTag(suggestion.name) } label: {
                            ShareTagPillLabel(name: suggestion.name,
                                              color: Color(hex: suggestion.appearance.colorHex) ?? .accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Preview

    @ViewBuilder
    private var previews: some View {
        if !isLoading, !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(items.count == 1 ? "Preview" : "Previews")

                ForEach(items) { item in
                    ShareThumbnailCard(item: item)
                }
            }
        }
    }

    /// Existing tags not already added, narrowed to what has been typed so far
    /// so the field doubles as a quick filter once the library has more than a
    /// handful of tags.
    private var tagSuggestions: [TagSnapshot] {
        let added = Set(tags.map { $0.lowercased() })
        let query = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return existingTags
            .filter { !added.contains($0.name.lowercased()) }
            .filter { query.isEmpty || $0.name.lowercased().contains(query) }
            .prefix(8)
            .map { $0 }
    }

    private func addDraftTag() {
        let name = tagDraft
        tagDraft = ""
        addTag(name)
    }

    private func addTag(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        tags.append(trimmed)
    }

    // MARK: Loading

    private func load() async {
        async let previewItems = buildPreviewItems()

        do {
            let service = try await SharedLibrary.shared.current().service
            var flattened: [(FolderSnapshot, Int)] = []
            var queue: [(FolderSnapshot, Int)] = await service.rootFolders().map { ($0, 0) }
            while !queue.isEmpty {
                let (folder, depth) = queue.removeFirst()
                flattened.append((folder, depth))
                let children = await service.subfolders(of: folder.id).map { ($0, depth + 1) }
                queue.insert(contentsOf: children, at: 0)
            }
            folders = flattened
            collections = await service.collections()
            existingTags = await service.tags()
        } catch {
            state = .failed("Nook’s library couldn’t be opened.")
        }

        items = await previewItems
        isLoading = false
    }

    private func buildPreviewItems() async -> [SharePreviewItem] {
        var result: [SharePreviewItem] = []
        for (index, attachment) in attachments.enumerated() {
            let provider = attachment.provider
            guard let resolved = await ShareItemResolver.resolve(provider) else { continue }
            let fallbackName = ShareItemResolver.displayName(for: provider)
            result.append(
                await SharePreview.makeItem(
                    id: index,
                    resolved: resolved,
                    fallbackName: fallbackName,
                    attachedMetadata: await LinkMetadataFetcher.attachedMetadataData(from: provider),
                    sharedTitle: attachment.sharedTitle
                )
            )
        }
        return result
    }

    // MARK: Saving

    private func save() async {
        guard state != .saving, !items.isEmpty else { return }
        state = .saving

        let pendingTag = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var tagsToSave = tags
        if !pendingTag.isEmpty,
           !tagsToSave.contains(where: { $0.caseInsensitiveCompare(pendingTag) == .orderedSame }) {
            tagsToSave.append(pendingTag)
        }

        do {
            let library = try await SharedLibrary.shared.current()
            defer {
                for item in items { item.resolved.removeTemporaryFiles() }
            }

            let report = await library.service.importItems(
                items.map(\.resolved.importItem),
                into: importDestination
            )

            var importedIDs: [ObjectID] = []
            for (index, result) in report.results.enumerated() {
                guard let objectID = result.objectID else { continue }
                importedIDs.append(objectID)
                let title = items[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = items[index].notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty || !notes.isEmpty {
                    try? await library.service.updateObject(
                        objectID,
                        title: title.isEmpty ? nil : title,
                        notes: notes.isEmpty ? nil : notes
                    )
                }

                // Metadata fetched while the sheet was open is applied now, so
                // the app doesn't need to fetch the page again on next launch.
                if let linkMetadata = items[index].linkMetadata {
                    try? await library.service.applyLinkMetadata(linkMetadata.metadata, to: objectID)
                    if let imageData = linkMetadata.previewImageData {
                        await library.thumbnails.storePreviewImage(imageData, for: objectID)
                    }
                }
            }

            guard !importedIDs.isEmpty else {
                state = .failed("Couldn't save these items.")
                return
            }

            if destination == .hidden {
                try? await library.service.setHidden(true, forObjects: importedIDs)
            }

            for tag in tagsToSave {
                try? await library.service.addTag(named: tag, to: importedIDs)
            }
            if let collectionID {
                try? await library.service.addObjects(importedIDs, toCollection: collectionID)
            }

            // Made here, while the originals are certainly on this device and
            // before the sheet goes away. The other devices are about to
            // receive these records over CloudKit, and without a picture
            // riding along they have nothing to show until the originals
            // themselves finish syncing — which is a different, slower system.
            for objectID in importedIDs {
                try? await library.service.generateSyncedThumbnail(
                    for: objectID,
                    using: library.thumbnails
                )
            }

            onFinish()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Item details

private struct ShareItemDetailsCard: View {
    @Binding var item: SharePreviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailField(label: "Title") {
                TextField("Title", text: $item.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
            }

            Divider()

            DetailField(label: item.kind == .link ? "URL" : "Source") {
                Text(item.source)
                    .font(.body)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Divider()

            TextField("Add a note", text: $item.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .clipShape(.rect(cornerRadius: 20))
    }
}

private struct DetailField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview card

private struct ShareThumbnailCard: View {
    let item: SharePreviewItem

    var body: some View {
        Group {
            if let image = item.image {
                image
                    .resizable()
                    .aspectRatio(item.aspectRatio ?? 1, contentMode: .fit)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary.opacity(0.5))
                    Image(systemName: item.kind.symbolName)
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .aspectRatio(item.aspectRatio ?? 16.0 / 9.0, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 320)
        .clipShape(.rect(cornerRadius: 20))
    }
}

// MARK: - Destination

private struct DestinationRow: View {
    let systemImage: String
    let title: String
    let value: String
    var isExpanded = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 19))
                .foregroundStyle(.tint)
                .frame(width: 24)

            Text(title)

            Spacer()

            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
    }
}

private struct ShareDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 52)
    }
}

private struct SectionHeading: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

// MARK: - Tags

/// A tag shown as a pill with a way to remove it, for tags already chosen.
private struct ShareTagPill: View {
    let name: String
    let color: Color
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(name)")
            Button("Remove", systemImage: "xmark", action: onRemove)
                .labelStyle(.iconOnly)
                .font(.system(size: 8, weight: .bold))
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.16), in: Capsule())
    }
}

/// A tag shown as a plain pill, for suggestions that add on tap.
private struct ShareTagPillLabel: View {
    let name: String
    let color: Color

    var body: some View {
        Text("#\(name)")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.1), in: Capsule())
    }
}

/// A wrapping layout for pills whose widths are determined by their labels.
private struct ShareTagFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height + spacing }
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: max(0, height - spacing))
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }

        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

private extension Color {
    /// Parses `#RRGGBB`, used for tag colours stored as text.
    init?(hex: String?) {
        guard let hex else { return nil }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}

import SwiftUI
import NookLibrary

/// Choose where it goes, then save it.
///
/// The destination picker is the point of the sheet: import is context-aware
/// everywhere else in the app, and the share sheet is the one place with no
/// context to infer, so it asks. The card above it previews the item the way
/// it will actually sit on the wall in Nook, rather than a bare file name,
/// because the wall — not a Files-style list — is what the user is saving into.
struct MacShareView: View {
    let providers: [NSItemProvider]
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
                VStack(spacing: 18) {
                    previewCards

                    if case .failed(let message) = state {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    quickPickers
                    tagsEditor
                }
                .padding(16)
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
        .frame(minWidth: 460, idealWidth: 480, minHeight: 560, idealHeight: 620)
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

    // MARK: Preview

    @ViewBuilder
    private var previewCards: some View {
        if isLoading {
            RoundedRectangle(cornerRadius: 16)
                .fill(.quaternary.opacity(0.5))
                .frame(height: 200)
                .overlay { ProgressView() }
        } else if items.isEmpty {
            Label("Nothing here could be saved.", systemImage: "questionmark.folder")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ForEach($items) { $item in
                SharePreviewCard(item: $item)
            }
        }
    }

    // MARK: Destination & collection

    private var quickPickers: some View {
        VStack(spacing: 10) {
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
                QuickPickerLabel(systemImage: destinationSystemImage, title: "Folder", value: destinationName)
            }
            .menuStyle(.borderlessButton)

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
                QuickPickerLabel(systemImage: "rectangle.stack.fill", title: "Collection", value: collectionName)
            }
            .menuStyle(.borderlessButton)
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
        destination == .hidden ? "eye.slash" : "folder.fill"
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
            Label("Tags", systemImage: "tag.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
        for (index, provider) in providers.enumerated() {
            guard let resolved = await ShareItemResolver.resolve(provider) else { continue }
            let fallbackName = ShareItemResolver.displayName(for: provider)
            result.append(await SharePreview.makeItem(id: index, resolved: resolved, fallbackName: fallbackName))
        }
        return result
    }

    // MARK: Saving

    private func save() async {
        guard state != .saving, !items.isEmpty else { return }
        state = .saving
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
                if !title.isEmpty {
                    try? await library.service.updateObject(objectID, title: title)
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

            for tag in tags {
                try? await library.service.addTag(named: tag, to: importedIDs)
            }
            if let collectionID {
                try? await library.service.addObjects(importedIDs, toCollection: collectionID)
            }

            onFinish()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Preview card

/// One item as it will sit on the wall: the picture at its own proportions,
/// with the name it will be saved under editable right on the card instead of
/// off in a separate field, since it is what the card is captioned with.
private struct SharePreviewCard: View {
    @Binding var item: SharePreviewItem

    private let radius: CGFloat = 16

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
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .aspectRatio(item.aspectRatio ?? 4.0 / 3.0, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 280)
        .overlay(alignment: .bottom) { titleField }
        .clipShape(.rect(cornerRadius: radius))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    private var titleField: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Title", text: $item.title)
                .font(.callout.weight(.medium))
                .textFieldStyle(.plain)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}

// MARK: - Quick picker

private struct QuickPickerLabel: View {
    let systemImage: String
    let title: String
    let value: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
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

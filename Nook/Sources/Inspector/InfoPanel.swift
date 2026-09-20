import SwiftUI
import NookLibrary

/// Metadata on demand.
///
/// The panel is closed by default and never becomes permanent chrome: the
/// canvas is for content, and this is where the details wait until asked for.
struct InfoPanel: View {
    let model: LibraryModel

    @State private var titleDraft = ""
    @State private var notesDraft = ""
    @State private var tagDraft = ""
    @State private var editingID: ObjectID?
    @FocusState private var isEditingText: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var object: ObjectSnapshot? {
        model.previewedObject ?? model.selectedObjects.first
    }

    /// Which of the panel's three faces is showing. Walking the selection
    /// moves between them, and a form dissolving through an empty state is
    /// two panels of text on top of each other, so they are swapped.
    private enum InfoFace: Equatable {
        case multiple
        case object
        case none
    }

    /// Named by which face rather than by which object: walking from one item
    /// to the next keeps the same form, and animating its fields relaying out
    /// would be a different change than the one this is here to cover.
    private var face: InfoFace {
        if model.selectedObjects.count > 1 { return .multiple }
        return object == nil ? .none : .object
    }

    var body: some View {
        Group {
            if model.selectedObjects.count > 1 {
                multipleSelection
                    .transition(.nookSwap(reduceMotion: reduceMotion))
            } else if let object {
                details(for: object)
                    .transition(.nookSwap(reduceMotion: reduceMotion))
            } else {
                ContentUnavailableView("No Selection", systemImage: "info.circle",
                                       description: Text("Select an item to see its details."))
                    .transition(.nookSwap(reduceMotion: reduceMotion))
            }
        }
        .nookMotion(.presentation, value: face)
        .task(id: object?.id) { loadDrafts() }
        .onChange(of: isEditingText) { _, editing in model.isTextEntryFocused = editing }
        .onDisappear { model.isTextEntryFocused = false }
    }

    // MARK: States

    private var multipleSelection: some View {
        let objects = model.selectedObjects
        return ContentUnavailableView {
            Label("\(objects.count) Items Selected", systemImage: "square.on.square")
        } description: {
            Text(objects.compactMap { Format.bytes($0.byteSize) }.isEmpty
                 ? "Multiple items"
                 : "\(objects.count) items selected")
        }
    }

    @ViewBuilder
    private func details(for object: ObjectSnapshot) -> some View {
        Form {
            if object.visibility.isRedacted {
                Section {
                    Label("This item is locked", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField("Title", text: $titleDraft, axis: .vertical)
                        .focused($isEditingText)
                        .onSubmit { commitTitle(for: object) }
                    TextField("Notes", text: $notesDraft, axis: .vertical)
                        .focused($isEditingText)
                        .lineLimit(3...8)
                }

                Section("Tags") {
                    if !object.tags.isEmpty {
                        TagFlow(spacing: 4) {
                            ForEach(object.tags) { tag in
                                TagPill(
                                    tag: tag,
                                    onSelect: {
                                        model.navigate(to: .scope(.tag(tag.id)))
                                    },
                                    onRemove: {
                                        Task { await model.removeTag(tag.id, from: [object.id]) }
                                    }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    TextField("Add a tag", text: $tagDraft)
                        .focused($isEditingText)
                        .onSubmit {
                            let name = tagDraft
                            tagDraft = ""
                            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                            Task { await model.addTag(name, to: [object.id]) }
                        }
                }

                Section {
                    if let url = object.kind == .link ? object.sourceURL : model.localURL(for: object) {
                        Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                            OpenExternally.open(url)
                        }
                    }
                }

                Section("Details") {
                    row("Kind", object.kind.displayName)
                    row("Where", object.folderName ?? "Inbox")
                    row("Filename", object.originalFilename)
                    row("Size", Format.bytes(object.byteSize))
                    row("Dimensions", Format.dimensions(object))
                    row("Duration", Format.duration(object.duration))
                    row("Pages", object.pageCount.map(String.init))
                    row("Added", Format.date(object.dateAdded))
                    row("Created", Format.date(object.dateCreated))
                    if let url = object.sourceURL {
                        LabeledContent("Source") {
                            Link(url.host() ?? url.absoluteString, destination: url)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { commitEdits(for: object) }
        .onChange(of: model.previewedObjectID) { commitEdits(for: object) }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
        }
    }

    // MARK: Editing

    private func loadDrafts() {
        guard let object else { return }
        editingID = object.id
        titleDraft = object.title
        notesDraft = object.notes
    }

    private func commitTitle(for object: ObjectSnapshot) {
        guard titleDraft != object.title else { return }
        let title = titleDraft
        Task { await model.update(object.id, title: title) }
    }

    /// Edits are written when focus leaves rather than on every keystroke.
    private func commitEdits(for object: ObjectSnapshot) {
        guard editingID == object.id else { return }
        let title = titleDraft == object.title ? nil : titleDraft
        let notes = notesDraft == object.notes ? nil : notesDraft
        guard title != nil || notes != nil else { return }
        Task { await model.update(object.id, title: title, notes: notes) }
    }
}

#if DEBUG
#Preview {
    PreviewHost { model in
        InfoPanel(model: model)
    }
    .frame(width: 320, height: 500)
}
#endif

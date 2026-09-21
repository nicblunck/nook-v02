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

    /// The panel shows one of three things, and moves between them the way
    /// the canvas moves between places: the old one fades out, then the new
    /// one fades in.
    var body: some View {
        ZStack {
            if model.selectedObjects.count > 1 {
                multipleSelection
                    .transition(swapTransition)
            } else if let object {
                details(for: object)
                    .id(object.id)
                    .transition(swapTransition)
            } else {
                ContentUnavailableView("No Selection", systemImage: "info.circle",
                                       description: Text("Select an item to see its details."))
                    .transition(swapTransition)
            }
        }
        .task(id: object?.id) { loadDrafts() }
        .onChange(of: isEditingText) { _, editing in model.isTextEntryFocused = editing }
        .onDisappear { model.isTextEntryFocused = false }
    }

    // MARK: States

    private var swapTransition: AnyTransition {
        .staged(reduceMotion: reduceMotion)
    }

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
                                // Tags are added one at a time, at the end,
                                // and removed one at a time: a new one has
                                // nothing to wait for, and the rest close up
                                // behind a removed one once it has gone.
                                .transition(.staged(
                                    exit: .scale(scale: 0.9).combined(with: .opacity),
                                    enter: .scale(scale: 0.9).combined(with: .opacity),
                                    enterDelay: 0,
                                    reduceMotion: reduceMotion
                                ))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(MotionChoreography(removes: true).shift(reduceMotion: reduceMotion),
                                   value: object.tags.map(\.id))
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

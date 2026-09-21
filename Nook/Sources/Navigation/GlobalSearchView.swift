import SwiftUI
import NookLibrary

/// Global Search: a floating, unscoped palette that can be opened from
/// anywhere without first navigating the canvas.
///
/// Deliberately not a boolean query builder. A field, immediate results, and a
/// type filter — enough to get to a known item fast, with everything else left
/// to browsing and filters.
struct GlobalSearchView: View {
    let model: LibraryModel
    let dismiss: () -> Void

    @State private var text = ""
    @State private var kinds: Set<ObjectKind> = []
    @State private var results: [ObjectSnapshot] = []
    /// The stages the latest change to `results` needs.
    @State private var resultsChange: MotionChoreography = .none
    @State private var highlighted: ObjectID?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            filters
            Divider()
            resultsList
        }
        .frame(maxWidth: 620)
        .frame(height: 460)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 14))
        .shadow(radius: 30, y: 10)
        .onAppear { isFieldFocused = true }
        .onDisappear { model.isTextEntryFocused = false }
        .onChange(of: isFieldFocused) { _, focused in model.isTextEntryFocused = focused }
        .onChange(of: text) { scheduleSearch() }
        .onChange(of: kinds) { scheduleSearch() }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { openHighlighted(); return .handled }
    }

    // MARK: Pieces

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your whole library", text: $text)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .onSubmit { openHighlighted() }
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .transition(.staged(
                        exit: .scale(scale: 0.8).combined(with: .opacity),
                        enter: .scale(scale: 0.8).combined(with: .opacity),
                        enterDelay: 0,
                        reduceMotion: reduceMotion
                    ))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .motionAware(NookMotion.interaction, value: text.isEmpty)
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ObjectKind.allCases) { kind in
                    let isOn = kinds.contains(kind)
                    Button {
                        if isOn { kinds.remove(kind) } else { kinds.insert(kind) }
                    } label: {
                        Label(kind.pluralDisplayName, systemImage: kind.symbolName)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                             : AnyShapeStyle(.quaternary.opacity(0.5)),
                                        in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .motionAware(NookMotion.interaction, value: isOn)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private var resultsList: some View {
        ZStack {
            if text.isEmpty {
                ContentUnavailableView("Search Everything", systemImage: "magnifyingglass",
                                       description: Text("Titles, filenames, notes, tags, folders, collections and links."))
                    .transition(.staged(reduceMotion: reduceMotion))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: text)
                    .transition(.staged(reduceMotion: reduceMotion))
            } else {
                resultRows
                    .transition(.staged(reduceMotion: reduceMotion))
            }
        }
    }

    private var resultRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results) { object in
                        resultRow(object)
                            .id(object.id)
                            // A result that no longer matches fades out; the
                            // rest close up; a new match fades in once they
                            // have.
                            .transition(resultsChange.itemTransition(
                                exit: .scale(scale: 0.98).combined(with: .opacity),
                                enter: .scale(scale: 0.98).combined(with: .opacity),
                                reduceMotion: reduceMotion
                            ))
                    }
                }
                .padding(8)
                .animation(resultsChange.shift(reduceMotion: reduceMotion),
                           value: results.map(\.id))
            }
            .onChange(of: highlighted) {
                guard let highlighted else { return }
                // Arrow-keying through results still has to bring the row
                // into view; Reduce Motion only asks that it not scroll
                // there.
                withAnimation(reduceMotion ? nil : .default) {
                    proxy.scrollTo(highlighted, anchor: .center)
                }
            }
        }
    }

    private func resultRow(_ object: ObjectSnapshot) -> some View {
        HStack(spacing: 10) {
            ThumbnailView(object: object, maximumSize: 128)
                .frame(width: 32, height: 32)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(object.title).lineLimit(1)
                Text(location(of: object))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(object.kind.displayName)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(highlighted == object.id ? AnyShapeStyle(Color.accentColor.opacity(0.2))
                                               : AnyShapeStyle(.clear))
        }
        .contentShape(.rect)
        .onTapGesture { open(object) }
        .onHover { if $0 { highlighted = object.id } }
        .motionAware(NookMotion.interaction, value: highlighted == object.id)
    }

    private func location(of object: ObjectSnapshot) -> String {
        object.folderName ?? "Inbox"
    }

    // MARK: Behaviour

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = text
        let kindFilter = kinds
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            show([])
            highlighted = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let found = await model.library.service.objects(
                matching: ObjectQuery(scope: .allObjects, searchText: query, kinds: kindFilter, limit: 60),
                in: model.accessContext
            )
            guard !Task.isCancelled else { return }
            show(found)
            highlighted = found.first?.id
        }
    }

    /// Works out the stages the change needs before showing it, so the rows
    /// read them off the same update.
    private func show(_ found: [ObjectSnapshot]) {
        resultsChange = MotionChoreography(from: results.map(\.id), to: found.map(\.id))
        results = found
    }

    private func move(_ offset: Int) {
        guard !results.isEmpty else { return }
        guard let current = highlighted, let index = results.firstIndex(where: { $0.id == current }) else {
            highlighted = results.first?.id
            return
        }
        let next = (index + offset).clamped(to: 0...(results.count - 1))
        highlighted = results[next].id
    }

    private func openHighlighted() {
        guard let highlighted, let object = results.first(where: { $0.id == highlighted }) else { return }
        open(object)
    }

    /// Results open into the normal app context rather than into a separate
    /// results mode: the canvas navigates to where the object actually lives.
    private func open(_ object: ObjectSnapshot) {
        dismiss()
        Task {
            model.navigate(to: .scope(object.folderID.map { LibraryScope.folder($0) } ?? .inbox))
            await model.loadPreferences()
            await model.refreshContents()
            // A result buried in a locked folder can only have appeared here
            // while that folder was already authenticated, so it is always
            // safe to open directly — falling back to the search snapshot
            // only covers the ordinary refresh race, not a lock.
            let landed = model.contents.objects.first { $0.id == object.id } ?? object
            model.openObject(landed)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#if DEBUG
#Preview {
    PreviewHost { model in
        GlobalSearchView(model: model, dismiss: {})
    }
    .frame(width: 700, height: 550)
}
#endif

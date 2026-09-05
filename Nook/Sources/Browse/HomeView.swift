import SwiftUI
import NookLibrary

/// A restrained way back into recent work — not a dashboard.
///
/// Each band is a window onto a place that already exists in the library, so
/// nothing here is a separate store or a separate idea; the header is a way in.
struct HomeView: View {
    @Bindable var model: LibraryModel

    /// Which tile the last click landed on. Home has no selection of its own —
    /// nothing acts on this but the highlight — so it lives here rather than
    /// on the model.
    @State private var highlighted: ObjectID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(model.homeSections) { section in
                    band(section)
                }

                if model.homeSections.allSatisfy(\.objects.isEmpty) {
                    ContentUnavailableView {
                        Label("Your Library Is Empty", systemImage: "tray")
                    } description: {
                        Text("Drag files in, import them, or share something to Nook.")
                    } actions: {
                        Button("Import Files…") { model.isImporterPresented = true }
                    }
                    .padding(.top, 40)
                }
            }
            .padding(24)
        }
        .navigationTitle("Home")
    }

    private func band(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.navigate(to: .scope(section.scope))
            } label: {
                HStack(spacing: 6) {
                    Label(section.title, systemImage: section.symbolName)
                        .font(.title3.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(section.title)")

            if section.objects.isEmpty {
                Text(emptyCopy(for: section))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(section.objects) { object in
                            tile(object, in: section)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func tile(_ object: ObjectSnapshot, in section: HomeSection) -> some View {
        let isHighlighted = highlighted == object.id
        return VStack(alignment: .leading, spacing: 6) {
            ThumbnailView(object: object)
                .frame(width: 140, height: 110)
                .clipShape(.rect(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                }

            Text(object.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 140, alignment: .leading)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isHighlighted ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                    : AnyShapeStyle(.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: isHighlighted ? 1.5 : 0)
        }
        .contentShape(.rect(cornerRadius: 12))
        // The same two-step as the canvas: a click says which one, a double
        // click opens it. Home is an entry screen, not a different rulebook.
        .simultaneousGesture(TapGesture().onEnded { highlighted = object.id })
        .onTapGesture(count: 2) { open(object, in: section) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.title)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    /// Opening from Home lands in the place the item lives, with the rest of
    /// that place's contents around it, so the next and previous keys work.
    private func open(_ object: ObjectSnapshot, in section: HomeSection) {
        if object.kind == .link, let url = object.sourceURL {
            OpenExternally.open(url)
            return
        }
        model.navigate(to: .scope(section.scope))
        Task {
            await model.refreshContents()
            model.selection = [object.id]
            model.previewedObjectID = object.id
        }
    }

    private func emptyCopy(for section: HomeSection) -> String {
        switch section.scope {
        case .inbox: "Nothing waiting. Anything you import without choosing a folder appears here."
        default: "Nothing yet."
        }
    }
}

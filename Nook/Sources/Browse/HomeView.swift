import SwiftUI
import NookLibrary

/// Home's own coordinate space, so tiles in different bands are measured
/// against the same origin and can be compared across them.
private let homeCoordinateSpace = "nook.home"

/// The keys Home answers to — the canvas's, on Home's own order and frames.
private struct HomeKeyboard: ViewModifier {
    let model: LibraryModel
    let frames: [HomeTileID: CGRect]

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow],
                        phases: [.down, .repeat]) { press in
                guard let direction = CanvasDirection(press.key) else { return .ignored }
                let moved = model.moveHomeCursor(direction, frames: frames)
                // Left with nowhere left to go steps back into the sidebar,
                // exactly as it does on the canvas.
                if !moved, direction == .left { model.focus(.sidebar) }
                return .handled
            }
            .onKeyPress(keys: [.home, .end], phases: [.down]) { press in
                model.moveHomeCursorToEdge(press.key == .home ? .up : .down)
                return .handled
            }
            .onKeyPress(.tab) {
                model.focusOtherPane()
                return .handled
            }
            .onKeyPress(.return) {
                guard model.homeCursor != nil else { return .ignored }
                model.openHomeCursorItem()
                return .handled
            }
            .onKeyPress(.space) {
                guard model.homeCursor != nil else { return .ignored }
                model.previewHomeCursorItem()
                return .handled
            }
    }
}

/// A restrained way back into recent work — not a dashboard.
///
/// Each band is a window onto a place that already exists in the library, so
/// nothing here is a separate store or a separate idea; the header is a way in.
struct HomeView: View {
    @Bindable var model: LibraryModel

    /// Where each tile was drawn, which is what tells up and down what the
    /// band above means. Home's bands scroll sideways independently, so their
    /// tiles do not line up in columns and no index arithmetic finds them.
    @State private var tileFrames: [HomeTileID: CGRect] = [:]
    @FocusState private var isHomeFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            content
                .focusable()
                .focusEffectDisabled()
                .focused($isHomeFocused)
                .modifier(HomeKeyboard(model: model, frames: tileFrames))
                // Home is the other thing the canvas pane can be showing, so
                // it follows the same focus arbitration the canvas does.
                .onAppear { syncFocus() }
                .onChange(of: model.keyboardFocusRequest) { syncFocus() }
                .onChange(of: isHomeFocused) { _, focused in
                    if focused { model.focus(.canvas) }
                }
                .onChange(of: model.canvasEntryRequest) {
                    model.lightFirstItemIfNothingIsLit()
                }
                .onChange(of: model.homeCursor) { _, cursor in
                    guard let cursor else { return }
                    proxy.scrollTo(cursor)
                }
                .onChange(of: model.homeOrder) { _, order in
                    let present = Set(order)
                    tileFrames = tileFrames.filter { present.contains($0.key) }
                }
        }
    }

    private var content: some View {
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
            .coordinateSpace(.named(homeCoordinateSpace))
        }
        .navigationTitle("Home")
    }

    /// Puts the keyboard where the model says it belongs.
    private func syncFocus() {
        isHomeFocused = model.keyboardPane == .canvas
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
        // The band is part of the tile's identity: Inbox and Recent are
        // separate queries, so the same object is routinely in both, and an
        // object id alone would light two tiles at once.
        let id = HomeTileID(scope: section.scope, object: object.id)
        let isHighlighted = model.homeCursor == id
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
        // The same rule as the canvas. Home is an entry screen, not a
        // different rulebook.
        .itemClick(select: { _ in
                       model.focus(.canvas)
                       model.homeCursor = id
                   },
                   open: { model.openHomeTile(id) })
        .id(id)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(homeCoordinateSpace))
        } action: { tileFrames[id] = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.title)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    private func emptyCopy(for section: HomeSection) -> String {
        switch section.scope {
        case .inbox: "Nothing waiting. Anything you import without choosing a folder appears here."
        default: "Nothing yet."
        }
    }
}

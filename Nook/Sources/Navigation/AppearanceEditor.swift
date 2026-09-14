import SwiftUI
import NookLibrary
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Everything the shared appearance sheet needs to either edit an existing
/// place or stage a new one. Creation is deliberately staged: nothing lands in
/// the library until Done is pressed.
struct AppearanceTarget: Identifiable, Equatable {
    enum Action {
        case edit(LibraryReference)
        case newFolder(parent: FolderID?)
        case newCollection(adding: [ObjectID])
        case newTag(adding: [ObjectID])
    }

    enum Kind: Equatable {
        case folder
        case collection
        case tag

        var fallbackSymbol: String {
            switch self {
            case .folder: "folder.fill"
            case .collection: "rectangle.stack"
            case .tag: "number"
            }
        }

        var newName: String {
            switch self {
            case .folder: "New Folder"
            case .collection: "New Collection"
            case .tag: "New Tag"
            }
        }

        var customizeTitle: LocalizedStringResource {
            switch self {
            case .folder: "Customize Folder"
            case .collection: "Customize Collection"
            case .tag: "Customize Tag"
            }
        }

        var newTitle: LocalizedStringResource {
            switch self {
            case .folder: "New Folder"
            case .collection: "New Collection"
            case .tag: "New Tag"
            }
        }
    }

    let id = UUID()
    let action: Action
    let kind: Kind
    let initialName: String
    let initialAppearance: EntityAppearance

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    init(reference: LibraryReference, title: String, appearance: EntityAppearance) {
        self.action = .edit(reference)
        self.kind = switch reference {
        case .folder: .folder
        case .collection: .collection
        case .tag: .tag
        case .object: .folder
        }
        self.initialName = title
        self.initialAppearance = appearance
    }

    private init(action: Action, kind: Kind) {
        self.action = action
        self.kind = kind
        self.initialName = kind.newName
        self.initialAppearance = .system
    }

    static func newFolder(parent: FolderID?) -> Self {
        Self(action: .newFolder(parent: parent), kind: .folder)
    }

    static func newCollection(adding ids: [ObjectID]) -> Self {
        Self(action: .newCollection(adding: ids), kind: .collection)
    }

    static func newTag(adding ids: [ObjectID] = []) -> Self {
        Self(action: .newTag(adding: ids), kind: .tag)
    }

    var isNew: Bool {
        switch action {
        case .edit: false
        case .newFolder, .newCollection, .newTag: true
        }
    }

    var editorTitle: LocalizedStringResource {
        isNew ? kind.newTitle : kind.customizeTitle
    }
}

/// The one editor for folders, collections and tags, used for both creation
/// and later customization. Its shape follows the original Nook editor: the
/// name and live identity preview sit above a compact palette and a searchable
/// icon catalogue.
struct AppearanceEditor: View {
    let target: AppearanceTarget
    let onSave: (String, EntityAppearance) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryModel.self) private var model
    @State private var draftName: String
    @State private var appearance: EntityAppearance
    @State private var isSaving = false

    init(target: AppearanceTarget,
         onSave: @escaping (String, EntityAppearance) async -> Void) {
        self.target = target
        self.onSave = onSave
        self._draftName = State(initialValue: target.initialName)
        self._appearance = State(initialValue: target.initialAppearance)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    AppearancePreviewHeader(
                        kind: target.kind,
                        appearance: appearance,
                        name: $draftName,
                        autofocus: target.isNew,
                        onFocusChange: { model.isTextEntryFocused = $0 },
                        onSubmit: save
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .background(.background.secondary, in: .rect(cornerRadius: 18))

                    AppearancePicker(appearance: $appearance) {
                        model.isTextEntryFocused = $0
                    }
                    .padding(20)
                    .background(.background.secondary, in: .rect(cornerRadius: 18))
                }
                .padding(16)
            }
            .background(Color.primary.opacity(0.035))
            .navigationTitle(target.editorTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                        .disabled(isSaving || draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onDisappear { model.isTextEntryFocused = false }
        #if os(macOS)
        .frame(width: 380, height: 560)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private func save() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            await onSave(name, appearance)
            dismiss()
        }
    }
}

private struct AppearancePreviewHeader: View {
    let kind: AppearanceTarget.Kind
    let appearance: EntityAppearance
    @Binding var name: String
    let autofocus: Bool
    let onFocusChange: (Bool) -> Void
    let onSubmit: () -> Void

    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                EntityIcon(
                    appearance: appearance,
                    fallbackSymbol: kind.fallbackSymbol,
                    size: 48
                )
            }
            .frame(width: 96, height: 96)

            HStack(spacing: 1) {
                if kind == .tag {
                    Text("#")
                        .foregroundStyle(.secondary)
                }
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($isNameFocused)
                    .onSubmit(onSubmit)
            }
            .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if autofocus { isNameFocused = true }
        }
        .onChange(of: isNameFocused) { _, focused in
            onFocusChange(focused)
        }
    }

    private var tint: Color {
        Color(hex: appearance.colorHex) ?? .accentColor
    }
}

private struct AppearancePicker: View {
    @Binding var appearance: EntityAppearance
    let onFocusChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var emojiDraft = ""
    @State private var customColor = Color.accentColor
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isEmojiFocused: Bool

    private static let palette: [AppearanceColorOption] = [
        AppearanceColorOption(id: "default", name: "Default", hex: nil),
        AppearanceColorOption(id: "red", name: "Red", hex: "#FF3B30"),
        AppearanceColorOption(id: "orange", name: "Orange", hex: "#FF9500"),
        AppearanceColorOption(id: "yellow", name: "Yellow", hex: "#FFCC00"),
        AppearanceColorOption(id: "green", name: "Green", hex: "#34C759"),
        AppearanceColorOption(id: "teal", name: "Teal", hex: "#00C7BE"),
        AppearanceColorOption(id: "blue", name: "Blue", hex: "#007AFF"),
        AppearanceColorOption(id: "indigo", name: "Indigo", hex: "#5856D6"),
        AppearanceColorOption(id: "purple", name: "Purple", hex: "#AF52DE")
    ]

    private var groups: [AppearanceIconGroup] {
        AppearanceIconCatalog.groups(matching: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Color")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if appearance != .system {
                    Button("Reset") {
                        appearance = .system
                        emojiDraft = ""
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 10) {
                ForEach(Self.palette) { option in
                    colorButton(option)
                }
                customColorPicker
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Icon")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    searchField
                    emojiField
                }
            }

            iconGrid
        }
        .onAppear {
            emojiDraft = appearance.emoji ?? ""
            customColor = Color(hex: appearance.colorHex) ?? .accentColor
        }
        .onChange(of: isSearchFocused) { _, _ in
            syncFocus()
        }
        .onChange(of: isEmojiFocused) { _, _ in
            syncFocus()
        }
        .onChange(of: customColor) { _, color in
            guard let hex = color.hexRGB else { return }
            appearance.colorHex = hex
        }
    }

    private func colorButton(_ option: AppearanceColorOption) -> some View {
        let selected = appearance.colorHex == option.hex
        return Button {
            appearance.colorHex = option.hex
        } label: {
            Circle()
                .fill(Color(hex: option.hex) ?? .accentColor)
                .frame(width: 28, height: 28)
                .overlay {
                    Circle()
                        .stroke(Color(hex: option.hex) ?? .accentColor, lineWidth: 2)
                        .frame(width: 36, height: 36)
                        .opacity(selected ? 1 : 0)
                }
                .scaleEffect(reduceMotion || !selected ? 1 : 1.08)
                .frame(height: 36)
        }
        .buttonStyle(.plain)
        .motionAware(NookMotion.interaction, value: selected)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var customColorPicker: some View {
        let isPreset = Self.palette.contains { $0.hex == appearance.colorHex }
        let selected = appearance.colorHex != nil && !isPreset
        return ColorPicker("Custom Color", selection: $customColor, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 36, height: 36)
            .scaleEffect(reduceMotion || !selected ? 1 : 1.08)
            .motionAware(NookMotion.interaction, value: selected)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search Icons", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
            if !query.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") {
                    query = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var emojiField: some View {
        HStack(spacing: 5) {
            Image(systemName: "face.smiling")
                .foregroundStyle(.secondary)
            TextField("Emoji", text: $emojiDraft)
                .textFieldStyle(.plain)
                .focused($isEmojiFocused)
                .frame(width: 46)
                .onChange(of: emojiDraft) { _, draft in
                    let emoji = draft.isEmpty ? nil : String(draft.prefix(1))
                    if draft != emoji { emojiDraft = emoji ?? "" }
                    appearance.emoji = emoji
                    if emoji != nil { appearance.symbolName = nil }
                }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    @ViewBuilder
    private var iconGrid: some View {
        if groups.isEmpty {
            Text("No icons match “\(query)”")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7),
                spacing: 8
            ) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.options) { option in
                            iconButton(option.symbol)
                        }
                    } header: {
                        Text(group.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func iconButton(_ symbol: String) -> some View {
        let selected = appearance.symbolName == symbol && appearance.emoji == nil
        let tint = Color(hex: appearance.colorHex) ?? .accentColor
        return Button {
            appearance.symbolName = symbol
            appearance.emoji = nil
            emojiDraft = ""
        } label: {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    selected ? tint.opacity(0.18) : Color.primary.opacity(0.05),
                    in: .rect(cornerRadius: 9)
                )
                .scaleEffect(reduceMotion || !selected ? 1 : 1.05)
        }
        .buttonStyle(.plain)
        .motionAware(NookMotion.interaction, value: selected)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func syncFocus() {
        onFocusChange(isSearchFocused || isEmojiFocused)
    }
}

private struct AppearanceColorOption: Identifiable {
    let id: String
    let name: LocalizedStringResource
    let hex: String?
}

private struct AppearanceIconOption: Identifiable {
    let symbol: String
    let terms: String

    var id: String { symbol }

    init(_ symbol: String, _ terms: String = "") {
        self.symbol = symbol
        self.terms = terms
    }

    func matches(_ query: String) -> Bool {
        symbol.contains(query) || terms.contains(query)
    }
}

private struct AppearanceIconGroup: Identifiable {
    let name: LocalizedStringResource
    let searchName: String
    let options: [AppearanceIconOption]

    var id: String { searchName }

    init(_ name: LocalizedStringResource, searchName: String, options: [AppearanceIconOption]) {
        self.name = name
        self.searchName = searchName
        self.options = options
    }
}

private enum AppearanceIconCatalog {
    static let all: [AppearanceIconGroup] = [
        AppearanceIconGroup("Folders", searchName: "folders", options: [
            .init("folder.fill"), .init("folder.badge.gearshape", "settings config"),
            .init("folder.badge.person.crop", "shared people"), .init("tray.full.fill", "inbox"),
            .init("archivebox.fill", "archive storage old"), .init("shippingbox.fill", "box package"),
            .init("externaldrive.fill", "disk drive backup"), .init("doc.fill", "file document"),
            .init("doc.text.fill", "file document text"), .init("doc.richtext.fill", "file document"),
            .init("note.text", "notes"), .init("book.fill", "reading journal diary"),
            .init("books.vertical.fill", "reading library shelf"), .init("newspaper.fill", "news articles")
        ]),
        AppearanceIconGroup("Work", searchName: "work", options: [
            .init("briefcase.fill", "job business"), .init("building.2.fill", "office company"),
            .init("calendar", "dates schedule planning"), .init("checklist", "todo tasks"),
            .init("list.bullet.clipboard.fill", "todo tasks project"), .init("chart.bar.fill", "stats data"),
            .init("chart.pie.fill", "stats data"), .init("dollarsign.circle.fill", "money finance invoice"),
            .init("creditcard.fill", "money payment finance"), .init("envelope.fill", "mail email"),
            .init("person.2.fill", "team clients people"), .init("target", "goals okr"),
            .init("lightbulb.fill", "ideas inspiration")
        ]),
        AppearanceIconGroup("Making", searchName: "making", options: [
            .init("paintbrush.fill", "design art creative"), .init("paintpalette.fill", "design art colour"),
            .init("pencil.and.outline", "sketch draw"), .init("ruler.fill", "design measure"),
            .init("scissors", "cut edit"), .init("camera.fill", "photos shoot"),
            .init("photo.fill", "picture image"), .init("film.fill", "video movie footage"),
            .init("video.fill", "movie recording"), .init("music.note", "audio song"),
            .init("headphones", "audio listening"), .init("waveform", "audio sound"),
            .init("wand.and.stars", "magic effects ai"), .init("sparkles", "magic new ai"),
            .init("hammer.fill", "build diy tools"), .init("wrench.and.screwdriver.fill", "maintenance fix")
        ]),
        AppearanceIconGroup("Code", searchName: "code", options: [
            .init("chevron.left.forwardslash.chevron.right", "programming dev"),
            .init("terminal.fill", "shell console"), .init("curlybraces", "programming json"),
            .init("gearshape.fill", "settings config"), .init("cpu", "hardware chip"),
            .init("server.rack", "backend hosting infra"), .init("network", "api web infra"),
            .init("cloud.fill", "hosting sync backup"), .init("ant.fill", "bug issues debug"),
            .init("keyboard.fill", "typing input"), .init("desktopcomputer", "mac computer"),
            .init("iphone", "mobile device ios")
        ]),
        AppearanceIconGroup("Life", searchName: "life", options: [
            .init("house.fill", "home personal"), .init("heart.fill", "love health favourite"),
            .init("star.fill", "favourite important"), .init("flame.fill", "hot streak urgent"),
            .init("leaf.fill", "nature plants garden"), .init("pawprint.fill", "pets animals"),
            .init("fork.knife", "food recipes cooking"), .init("cup.and.saucer.fill", "coffee drinks"),
            .init("cart.fill", "shopping groceries buy"), .init("gift.fill", "birthday presents"),
            .init("figure.walk", "exercise health"), .init("figure.run", "exercise running"),
            .init("dumbbell.fill", "gym fitness"), .init("bed.double.fill", "sleep home rest"),
            .init("gamecontroller.fill", "games play"), .init("graduationcap.fill", "school learning"),
            .init("cross.case.fill", "medical health doctor")
        ]),
        AppearanceIconGroup("Places", searchName: "places", options: [
            .init("map.fill", "travel navigation"), .init("mappin.and.ellipse", "location travel"),
            .init("globe", "world international web"), .init("airplane", "travel flights trips"),
            .init("car.fill", "driving travel"), .init("bicycle", "cycling travel"),
            .init("tram.fill", "transit commute"), .init("tent.fill", "camping outdoors"),
            .init("mountain.2.fill", "hiking nature"), .init("beach.umbrella.fill", "holiday summer"),
            .init("sun.max.fill", "weather day"), .init("moon.fill", "night sleep"),
            .init("cloud.sun.fill", "weather"), .init("snowflake", "winter cold")
        ]),
        AppearanceIconGroup("Marks", searchName: "marks", options: [
            .init("tag.fill", "label category"), .init("bookmark.fill", "saved read later"),
            .init("flag.fill", "priority important"), .init("bell.fill", "reminders alerts"),
            .init("pin.fill", "pinned important"), .init("lock.fill", "private secure"),
            .init("key.fill", "password secure"), .init("shield.fill", "security private safe"),
            .init("exclamationmark.triangle.fill", "warning urgent"),
            .init("questionmark.circle.fill", "unknown maybe"),
            .init("checkmark.seal.fill", "done approved verified"), .init("clock.fill", "time history"),
            .init("hourglass", "waiting pending later"), .init("bolt.fill", "fast energy quick"),
            .init("brain.head.profile", "thinking ideas mind"), .init("eye.fill", "watch review"),
            .init("face.smiling", "fun personal happy"), .init("circle.fill", "dot shape"),
            .init("square.fill", "shape"), .init("triangle.fill", "shape"),
            .init("hexagon.fill", "shape"), .init("number", "hash tag topic"), .init("infinity", "ongoing")
        ])
    ]

    static func groups(matching rawQuery: String) -> [AppearanceIconGroup] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return all }
        return all.compactMap { group in
            if group.searchName.contains(query) { return group }
            let options = group.options.filter { $0.matches(query) }
            guard !options.isEmpty else { return nil }
            return AppearanceIconGroup(group.name, searchName: group.searchName, options: options)
        }
    }
}

private extension Color {
    var hexRGB: String? {
        #if os(macOS)
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        let color = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #endif
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

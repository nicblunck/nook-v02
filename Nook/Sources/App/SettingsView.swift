import SwiftUI
import NookLibrary

/// The global defaults, and nothing that belongs to a single location.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    /// The folders a start page can be, indented by depth.
    var folders: [(folder: FolderSnapshot, depth: Int)] = []

    /// The folders read from the library itself, for the Mac's Settings
    /// window, which is opened without a library window's folder list.
    @State private var loadedFolders: [(folder: FolderSnapshot, depth: Int)] = []

    #if os(macOS)
    @State private var selection = SettingsPane.appearance
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    #endif

    private static let tints: [(name: String, hex: String?)] = [
        ("System", nil),
        ("Red", "#FF3B30"), ("Orange", "#FF9500"), ("Yellow", "#FFCC00"),
        ("Green", "#34C759"), ("Teal", "#00C7BE"), ("Blue", "#007AFF"),
        ("Indigo", "#5856D6"), ("Purple", "#AF52DE"), ("Graphite", "#8E8E93")
    ]

    var body: some View {
        #if os(macOS)
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbolName)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .navigationTitle("Settings")
        } detail: {
            selectedPane
                .navigationTitle(selection.title)
                .navigationSubtitle(selection.subtitle)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, minHeight: 460)
        #else
        Form {
            startPageSection
            appearanceSection
            privacySection
            librarySection
            quickSaveSection
            linksSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .navigationSubtitle("Appearance, privacy, and library defaults")
        #endif
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Mode", selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }
            Toggle("Minimal Mode", isOn: $settings.isMinimalMode)
            Picker("Accent Color", selection: $settings.accentColorHex) {
                ForEach(Self.tints, id: \.name) { tint in
                    HStack {
                        Circle()
                            .fill(Color(hex: tint.hex) ?? .accentColor)
                            .frame(width: 12, height: 12)
                        Text(tint.name)
                    }
                    .tag(tint.hex)
                }
            }
            // Minimal Mode's accent is black whatever is chosen here.
            .disabled(settings.isMinimalMode)
        }
    }

    #if os(iOS)
    private var startPageSection: some View {
        Section {
            Picker("Start Page", selection: startPageBinding) {
                Section {
                    Label("Library", systemImage: "list.bullet").tag(StartPage.library)
                    Label("All", systemImage: "square.grid.2x2").tag(StartPage.all)
                    Label("Inbox", systemImage: "tray").tag(StartPage.inbox)
                    Label("Recent", systemImage: "clock").tag(StartPage.recent)
                    Label("Favorites", systemImage: "star").tag(StartPage.favorites)
                }
                if !folders.isEmpty {
                    Section("Folders") {
                        ForEach(folders, id: \.folder.id) { entry in
                            Label {
                                Text(entry.folder.name)
                            } icon: {
                                EntityIcon(appearance: entry.folder.appearance, fallbackSymbol: "folder")
                            }
                            .padding(.leading, CGFloat(entry.depth) * 16)
                            .tag(StartPage.folder(entry.folder.id))
                        }
                    }
                }
            }
            .pickerStyle(.navigationLink)
        }
    }

    /// A start folder that has since been deleted reads as All, which is
    /// where it now takes you.
    private var startPageBinding: Binding<StartPage> {
        Binding(
            get: {
                if case .folder(let id) = settings.startPage,
                   !folders.contains(where: { $0.folder.id == id }) {
                    return .all
                }
                return settings.startPage
            },
            set: { settings.startPage = $0 }
        )
    }
    #endif

    private var privacySection: some View {
        Section {
            Picker("Close Automatically", selection: $settings.hiddenRevealTimeout) {
                ForEach(HiddenRevealTimeout.allCases) { timeout in
                    Text(timeout.displayName).tag(timeout)
                }
            }
            Toggle("Close When Nook Loses Focus", isOn: $settings.rehidesWhenAppLosesFocus)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Hidden and locked folders stay open while you use Nook. They close after this much inactivity.")
        }
    }

    private var librarySection: some View {
        Section {
            Picker("Sort By", selection: sortFieldBinding) {
                ForEach([ObjectSortField.name, .dateAdded, .dateCreated, .kind, .size], id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            Picker("Order", selection: sortAscendingBinding) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            Toggle("Folders First", isOn: foldersFirstBinding)
            Toggle("Group Folders", isOn: groupsFoldersBinding)
                .disabled(!settings.defaultPreferences.foldersFirst)
            Toggle("Group by Type", isOn: groupsByTypeBinding)
        } header: {
            Text("Default Sorting")
        } footer: {
            Text("Locations use this order unless you've asked one to remember its own.")
        }
    }

    private var quickSaveSection: some View {
        Section {
            Picker("Save To", selection: quickSaveFolderBinding) {
                Label("Inbox", systemImage: "tray").tag(FolderID?.none)
                if !availableFolders.isEmpty {
                    Section("Folders") {
                        ForEach(availableFolders, id: \.folder.id) { entry in
                            Text(String(repeating: "    ", count: entry.depth) + entry.folder.name)
                                .tag(FolderID?.some(entry.folder.id))
                        }
                    }
                }
            }
        } header: {
            Text("Quick Save")
        } footer: {
            Text("Quick Save in the share sheet saves straight here, without asking for a folder or tags.")
        }
        .task {
            guard folders.isEmpty, loadedFolders.isEmpty else { return }
            await loadFolders()
        }
    }

    private var availableFolders: [(folder: FolderSnapshot, depth: Int)] {
        folders.isEmpty ? loadedFolders : folders
    }

    /// A quick save folder that has since been deleted reads as Inbox, which
    /// is where quick saves now go.
    private var quickSaveFolderBinding: Binding<FolderID?> {
        Binding(
            get: {
                guard let id = settings.quickSaveFolderID,
                      availableFolders.contains(where: { $0.folder.id == id })
                else { return nil }
                return id
            },
            set: { settings.quickSaveFolderID = $0 }
        )
    }

    private func loadFolders() async {
        guard let service = try? await SharedLibrary.shared.current().service else { return }
        var flattened: [(folder: FolderSnapshot, depth: Int)] = []
        var queue: [(folder: FolderSnapshot, depth: Int)] = await service.rootFolders().map { ($0, 0) }
        while !queue.isEmpty {
            let entry = queue.removeFirst()
            flattened.append(entry)
            let children = await service.subfolders(of: entry.folder.id).map { ($0, entry.depth + 1) }
            queue.insert(contentsOf: children, at: 0)
        }
        loadedFolders = flattened
    }

    #if os(iOS)
    private var linksSection: some View {
        Section {
            Picker("Open Links In", selection: $settings.linkOpening) {
                ForEach(LinkOpening.allCases) { opening in
                    Text(opening.displayName).tag(opening)
                }
            }
        } header: {
            Text("Links")
        } footer: {
            Text("In Nook, a link opens in Safari over the app. Done brings you back.")
        }
    }
    #endif

    #if os(macOS)
    @ViewBuilder
    private var selectedPane: some View {
        Form {
            switch selection {
            case .appearance:
                appearanceSection
            case .privacy:
                privacySection
            case .library:
                librarySection
            case .quickSave:
                quickSaveSection
            }
        }
        .formStyle(.grouped)
    }
    #endif

    private var sortFieldBinding: Binding<ObjectSortField> {
        Binding(get: { settings.defaultPreferences.sort.field },
                set: { settings.defaultPreferences.sort = ObjectSort(field: $0, ascending: settings.defaultPreferences.sort.ascending) })
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(get: { settings.defaultPreferences.sort.ascending },
                set: { settings.defaultPreferences.sort = ObjectSort(field: settings.defaultPreferences.sort.field, ascending: $0) })
    }

    private var foldersFirstBinding: Binding<Bool> {
        Binding(get: { settings.defaultPreferences.foldersFirst },
                set: { settings.defaultPreferences.foldersFirst = $0 })
    }

    private var groupsFoldersBinding: Binding<Bool> {
        Binding(get: { settings.defaultPreferences.groupsFolders },
                set: { settings.defaultPreferences.groupsFolders = $0 })
    }

    private var groupsByTypeBinding: Binding<Bool> {
        Binding(get: { settings.defaultPreferences.groupsByType },
                set: { settings.defaultPreferences.groupsByType = $0 })
    }
}

#if os(macOS)
private enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case privacy
    case library
    case quickSave

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .privacy: "Privacy"
        case .library: "Library"
        case .quickSave: "Quick Save"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: "Choose how Nook looks"
        case .privacy: "Control when Hidden and locked folders close"
        case .library: "Set the default order for your items"
        case .quickSave: "Choose where Quick Save puts things"
        }
    }

    var symbolName: String {
        switch self {
        case .appearance: "paintbrush"
        case .privacy: "hand.raised"
        case .library: "books.vertical"
        case .quickSave: "bolt"
        }
    }
}
#endif

#if DEBUG
#Preview {
    SettingsView(settings: AppSettings(defaults: UserDefaults(suiteName: "nook.preview.settings")!))
}
#endif

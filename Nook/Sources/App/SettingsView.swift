import SwiftUI
import NookLibrary

/// The global defaults, and nothing that belongs to a single location.
struct SettingsView: View {
    @Bindable var settings: AppSettings

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
            appearanceSection
            privacySection
            librarySection
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
        }
    }

    private var privacySection: some View {
        Section {
            Picker("Hide Revealed Items", selection: $settings.hiddenRevealTimeout) {
                ForEach(HiddenRevealTimeout.allCases) { timeout in
                    Text(timeout.displayName).tag(timeout)
                }
            }
            Toggle("Re-hide When Nook Loses Focus", isOn: $settings.rehidesWhenAppLosesFocus)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Hidden items stay visible while you use Nook, then hide after this much inactivity.")
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
        } header: {
            Text("Default Sorting")
        } footer: {
            Text("Locations use this order unless you've asked one to remember its own.")
        }
    }

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
}

#if os(macOS)
private enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case privacy
    case library

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .privacy: "Privacy"
        case .library: "Library"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: "Choose how Nook looks"
        case .privacy: "Control how hidden items are protected"
        case .library: "Set the default order for your items"
        }
    }

    var symbolName: String {
        switch self {
        case .appearance: "paintbrush"
        case .privacy: "hand.raised"
        case .library: "books.vertical"
        }
    }
}
#endif

#if DEBUG
#Preview {
    SettingsView(settings: AppSettings(defaults: UserDefaults(suiteName: "nook.preview.settings")!))
}
#endif

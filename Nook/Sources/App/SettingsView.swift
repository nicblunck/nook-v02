import SwiftUI
import NookLibrary

/// The global defaults, and nothing that belongs to a single location.
struct SettingsView: View {
    @Bindable var settings: AppSettings

    private static let tints: [(name: String, hex: String?)] = [
        ("System", nil),
        ("Red", "#FF3B30"), ("Orange", "#FF9500"), ("Yellow", "#FFCC00"),
        ("Green", "#34C759"), ("Teal", "#00C7BE"), ("Blue", "#007AFF"),
        ("Indigo", "#5856D6"), ("Purple", "#AF52DE"), ("Graphite", "#8E8E93")
    ]

    var body: some View {
        Form {
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

            Section {
                Picker("View", selection: viewModeBinding) {
                    ForEach(LibraryViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                    }
                }
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
                Text("Default View")
            } footer: {
                Text("Locations follow these unless you've asked one to remember its own.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(macOS)
        .frame(width: 440)
        .padding(.vertical, 8)
        #endif
    }

    private var viewModeBinding: Binding<LibraryViewMode> {
        Binding(get: { settings.defaultPreferences.viewMode },
                set: { settings.defaultPreferences.viewMode = $0 })
    }

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

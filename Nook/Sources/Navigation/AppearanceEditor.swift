import SwiftUI
import NookLibrary

/// Colour, symbol or emoji for a folder, collection or tag.
///
/// Expressive but structured: a fixed palette and symbol set rather than a
/// free-form picker, so entities stay recognisable at a glance across the
/// sidebar, the canvas and every pill and picker they appear in. Custom image
/// covers are deliberately absent.
struct AppearanceEditor: View {
    let title: String
    @State var appearance: EntityAppearance
    let onSave: (EntityAppearance) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var emojiDraft = ""

    private static let palette: [String?] = [
        nil, "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
        "#00C7BE", "#007AFF", "#5856D6", "#AF52DE", "#8E8E93"
    ]

    private static let symbols = [
        "folder", "rectangle.stack", "tag", "star", "bookmark", "tray",
        "photo", "film", "waveform", "doc.richtext", "link", "camera.viewfinder",
        "paintbrush", "hammer", "book", "briefcase", "house", "globe"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 10) {
                        ForEach(Self.palette.indices, id: \.self) { index in
                            swatch(Self.palette[index])
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Symbol") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 10) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            symbolButton(symbol)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Emoji") {
                    TextField("Emoji", text: $emojiDraft)
                        .onChange(of: emojiDraft) {
                            // One emoji stands in for the symbol; keeping both
                            // would make the same entity look like two things.
                            appearance.emoji = emojiDraft.isEmpty ? nil : String(emojiDraft.prefix(1))
                            if appearance.emoji != nil { appearance.symbolName = nil }
                        }
                    if appearance.emoji != nil {
                        Button("Remove Emoji") {
                            emojiDraft = ""
                            appearance.emoji = nil
                        }
                    }
                }

                Section {
                    Button("Reset to Default Style") {
                        appearance = .system
                        emojiDraft = ""
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(appearance)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { emojiDraft = appearance.emoji ?? "" }
        #if os(macOS)
        .frame(width: 420, height: 480)
        #endif
    }

    private func swatch(_ hex: String?) -> some View {
        let isSelected = appearance.colorHex == hex
        return Button {
            appearance.colorHex = hex
        } label: {
            Circle()
                .fill(Color(hex: hex) ?? Color.secondary.opacity(0.35))
                .frame(width: 30, height: 30)
                .overlay {
                    if hex == nil {
                        Image(systemName: "circle.slash").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    Circle().strokeBorder(Color.primary, lineWidth: isSelected ? 2 : 0)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex == nil ? "Default color" : "Color \(hex!)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func symbolButton(_ symbol: String) -> some View {
        let isSelected = appearance.symbolName == symbol
        return Button {
            appearance.symbolName = isSelected ? nil : symbol
            if appearance.symbolName != nil {
                appearance.emoji = nil
                emojiDraft = ""
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 34, height: 34)
                .background(isSelected ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 7))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

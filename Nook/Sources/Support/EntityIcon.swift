import SwiftUI
import NookLibrary

/// An entity's identity marker: its emoji if it has one, otherwise its symbol
/// in its colour, otherwise the system default for that kind of entity.
///
/// One view for every surface — sidebar, canvas, pickers, pills — so a folder
/// looks like itself wherever it appears.
///
/// The icon is decorative. It appears only beside the entity's own name, and
/// spoken aloud it would prefix every folder with the name of its emoji or
/// symbol, so it is hidden from VoiceOver rather than announced twice.
struct EntityIcon: View {
    let appearance: EntityAppearance
    let fallbackSymbol: String
    var size: CGFloat = 15

    /// Text scales with the reader's type size, so an icon sitting on the same
    /// line has to scale with it or fall out of proportion.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    var body: some View {
        Group {
            if let emoji = appearance.emoji {
                Text(emoji).font(.system(size: scaledSize))
            } else {
                Image(systemName: appearance.symbolName ?? fallbackSymbol)
                    .font(.system(size: scaledSize))
                    .foregroundStyle(tint)
            }
        }
        .accessibilityHidden(true)
    }

    private var scaledSize: CGFloat { size * typeScale }

    private var tint: Color {
        Color(hex: appearance.colorHex) ?? .accentColor
    }
}

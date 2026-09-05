import SwiftUI
import NookLibrary

/// An entity's identity marker: its emoji if it has one, otherwise its symbol
/// in its colour, otherwise the system default for that kind of entity.
///
/// One view for every surface — sidebar, canvas, pickers, pills — so a folder
/// looks like itself wherever it appears.
struct EntityIcon: View {
    let appearance: EntityAppearance
    let fallbackSymbol: String
    var size: CGFloat = 15

    var body: some View {
        if let emoji = appearance.emoji {
            Text(emoji).font(.system(size: size))
        } else {
            Image(systemName: appearance.symbolName ?? fallbackSymbol)
                .font(.system(size: size))
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        Color(hex: appearance.colorHex) ?? .accentColor
    }
}

import Foundation

/// A colour written as a hex code — `#FF6B35`, or the short `#F63` — the way
/// it arrives on the clipboard from a design tool or a stylesheet.
public enum ColorCode {
    /// The code in the one form the library stores, `#RRGGBB` in capitals,
    /// or nil when the text isn't a colour code. The `#` is required: six
    /// letters and digits alone are as likely to be a word ("facade") or a
    /// number as a colour.
    public static func normalized(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()
        guard value.allSatisfy(\.isHexDigit) else { return nil }
        switch value.count {
        case 6: break
        case 3: value = value.map { "\($0)\($0)" }.joined()
        default: return nil
        }
        return "#" + value.uppercased()
    }

    /// Every code in a pasted run of them — one per line, or separated by
    /// spaces or commas, as a palette is usually copied — or nil unless the
    /// text is nothing but colour codes.
    public static func codes(in text: String) -> [String]? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
        guard !tokens.isEmpty else { return nil }
        let codes = tokens.compactMap { normalized(String($0)) }
        return codes.count == tokens.count ? codes : nil
    }
}

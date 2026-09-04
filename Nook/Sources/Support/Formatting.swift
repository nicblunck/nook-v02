import Foundation
import SwiftUI
import NookLibrary

enum Format {
    static func bytes(_ value: Int64?) -> String? {
        guard let value else { return nil }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds)
    }

    static func dimensions(_ object: ObjectSnapshot) -> String? {
        guard let width = object.pixelWidth, let height = object.pixelHeight else { return nil }
        return "\(width) × \(height)"
    }

    static func date(_ value: Date?) -> String? {
        guard let value else { return nil }
        return value.formatted(date: .abbreviated, time: .shortened)
    }

    /// The one-line secondary caption under a card.
    static func caption(for object: ObjectSnapshot) -> String {
        var parts: [String] = [object.kind.displayName]
        if let duration = duration(object.duration) { parts.append(duration) }
        else if let pages = object.pageCount { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        else if let size = bytes(object.byteSize) { parts.append(size) }
        else if let domain = object.sourceDomain { parts = [domain] }
        return parts.joined(separator: " · ")
    }
}

extension Color {
    /// Parses `#RRGGBB`, used for entity colours stored as text.
    init?(hex: String?) {
        guard let hex else { return nil }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}

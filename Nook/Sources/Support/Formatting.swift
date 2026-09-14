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
        captionParts(for: object).joined(separator: " · ")
    }

    /// The same caption, phrased for speech.
    ///
    /// Two things separate it from the written one. The interpunct that reads
    /// as a separator on screen is pronounced when spoken, so the parts are
    /// joined with commas instead. And favourite and locked are shown as a
    /// glyph that carries no label of its own, which would otherwise leave a
    /// locked object sounding identical to an unprotected one.
    static func spokenCaption(for object: ObjectSnapshot) -> String {
        var parts = captionParts(for: object)
        if object.isHidden { parts.append("Hidden") }
        if object.isFavorite { parts.append("Favorite") }
        if object.isLocked { parts.append("Locked") }
        return parts.joined(separator: ", ")
    }

    private static func captionParts(for object: ObjectSnapshot) -> [String] {
        var parts: [String] = [object.kind.displayName]
        if let duration = duration(object.duration) { parts.append(duration) }
        else if let pages = object.pageCount { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        else if let size = bytes(object.byteSize) { parts.append(size) }
        else if let domain = object.sourceDomain { parts = [domain] }
        return parts
    }

    /// A count of contained objects, spelled out rather than left as a bare
    /// number, so a sidebar row reads "Inbox, 12 items" and not "Inbox, 12".
    static func itemCount(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    static func folderCount(_ count: Int) -> String {
        count == 1 ? "1 folder" : "\(count) folders"
    }

    /// The one-line secondary caption under a folder card.
    static func caption(for folder: FolderSnapshot) -> String {
        folderCaptionParts(for: folder).joined(separator: " · ")
    }

    /// The same caption, phrased for speech.
    static func spokenCaption(for folder: FolderSnapshot) -> String {
        var parts = folderCaptionParts(for: folder)
        if folder.isHidden { parts.append("Hidden") }
        if folder.isLocked { parts.append("Locked") }
        return parts.joined(separator: ", ")
    }

    private static func folderCaptionParts(for folder: FolderSnapshot) -> [String] {
        var parts: [String] = []
        if folder.subfolderCount > 0 { parts.append(folderCount(folder.subfolderCount)) }
        parts.append(itemCount(folder.objectCount))
        return parts
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

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
    /// joined with commas instead. And favourite is shown as a glyph that
    /// carries no label of its own, which would otherwise leave a favourite
    /// object sounding identical to a plain one. Objects can't be locked in
    /// their own right — only a folder's caption ever says "Locked".
    static func spokenCaption(for object: ObjectSnapshot) -> String {
        var parts = captionParts(for: object)
        if object.isHidden { parts.append("Hidden") }
        if object.isFavorite { parts.append("Favorite") }
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

    /// The metadata line under a list row's title.
    ///
    /// Each kind of object is asked for what is worth knowing about that
    /// kind — a picture's proportions, a recording's length, a document's
    /// extent, a bookmark's address — rather than all of them being reduced
    /// to the one fact they happen to share. The row draws the type as a
    /// glyph beside this text, so the type's name is left out except where
    /// there is nothing else to say.
    static func listSubtitle(for object: ObjectSnapshot) -> String {
        let size = bytes(object.byteSize)
        switch object.kind {
        case .link:
            // The site it points at, and nothing else: a byte count of the
            // saved page says nothing anyone wants from a bookmark.
            return displayURL(object.sourceURL) ?? object.sourceDomain ?? object.kind.displayName
        case .image, .screenshot:
            return join(dimensions(object), size, or: object)
        case .video, .audio:
            return join(duration(object.duration), size, or: object)
        case .pdf:
            let pages = object.pageCount.map { $0 == 1 ? "1 page" : "\($0) pages" }
            return join(pages, size, or: object)
        case .file:
            return join(fileTypeName(for: object), size, or: object)
        }
    }

    private static func join(_ first: String?, _ second: String?, or object: ObjectSnapshot) -> String {
        let parts = [first, second].compactMap(\.self)
        return parts.isEmpty ? object.kind.displayName : parts.joined(separator: " · ")
    }

    /// Where a bookmark points, named by its site rather than by its whole
    /// address: the path is usually longer than the row and says less than
    /// the title already above it, while the site is what tells one saved
    /// link apart from the next at a glance.
    private static func displayURL(_ url: URL?) -> String? {
        guard let url, var host = url.host() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// What kind of file it is, taken from its own name — "ZIP", "SKETCH" —
    /// since a generic document glyph cannot say and "File" says nothing.
    private static func fileTypeName(for object: ObjectSnapshot) -> String? {
        guard let filename = object.originalFilename else { return nil }
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    /// The same metadata, phrased for speech, together with the state and
    /// tags a list row shows as glyphs and pills.
    ///
    /// The row's badges and tag capsules carry no labels of their own, and
    /// the tag strip drops whatever the width cannot take — so everything
    /// they stand for has to arrive here, where nothing is abbreviated away.
    static func spokenListRow(for object: ObjectSnapshot) -> String {
        var parts = [listSubtitle(for: object)]
        if object.isHidden { parts.append("Hidden") }
        if object.isFavorite { parts.append("Favorite") }
        if !object.tags.isEmpty {
            parts.append("Tagged \(object.tags.map(\.name).joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }

    /// A count of contained objects, spelled out rather than left as a bare
    /// number, so a sidebar row reads "Inbox, 12 items" and not "Inbox, 12".
    static func itemCount(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    static func folderCount(_ count: Int) -> String {
        count == 1 ? "1 folder" : "\(count) folders"
    }

    /// The one-line secondary caption under a folder card. A locked folder's
    /// counts are always zero — they describe what the door withholds, not
    /// what it holds — so "Locked" replaces them rather than sitting beside
    /// a misleading "0 items".
    static func caption(for folder: FolderSnapshot) -> String {
        folder.isLocked ? "Locked" : folderCaptionParts(for: folder).joined(separator: " · ")
    }

    /// The same caption, phrased for speech.
    static func spokenCaption(for folder: FolderSnapshot) -> String {
        guard !folder.isLocked else {
            return folder.isHidden ? "Locked, Hidden" : "Locked"
        }
        var parts = folderCaptionParts(for: folder)
        if folder.isHidden { parts.append("Hidden") }
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

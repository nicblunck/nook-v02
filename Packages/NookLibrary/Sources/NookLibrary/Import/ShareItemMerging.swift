import Foundation
import UniformTypeIdentifiers

/// One thing shared, as the person sees it, often reaches the extension as
/// several attachments: a page arrives as its link and again as plain text
/// carrying that link or the page's title, and an image can come both as the
/// picture and as a file of the same bytes. Saved one by one, each of those
/// becomes an object of its own, so a single share leaves a link and a text
/// file behind.
///
/// This folds those back into what was actually shared, before anything is
/// shown or saved.
extension ShareItemResolver {
    /// Text longer than this is something written, not a caption for a link.
    nonisolated static let captionLengthLimit = 280
    /// Text files larger than this are documents, never a stand-in for a link.
    nonisolated static let textInspectionLimit = 64 * 1024

    /// The items worth saving, each with the position of the attachment it came
    /// from. Dropped items have their temporary files removed.
    ///
    /// - Text that is nothing but a web address becomes that link.
    /// - The same link twice is saved once.
    /// - Text sent alongside a link is that link's caption — when it mentions
    ///   the link, or is a single short line such as the page title — and is
    ///   not saved separately.
    /// - The same bytes twice are saved once.
    public nonisolated static func merged(_ items: [ResolvedShareItem]) -> [(index: Int, item: ResolvedShareItem)] {
        let classified = items.map { item -> (item: ResolvedShareItem, text: String?, wasText: Bool) in
            let text = sharedText(in: item.importItem)
            if let text, let url = loneWebURL(in: text) {
                item.removeTemporaryFiles()
                return (ResolvedShareItem(importItem: .link(url)), nil, true)
            }
            return (item, text, false)
        }

        let links: [String] = classified.compactMap {
            if case .link(let url) = $0.item.importItem { return linkKey(url) }
            return nil
        }
        // A link the host sent as a link may carry the page's metadata with
        // it; the same address sent as text never does, so the real one wins
        // wherever it sits in the order.
        let sentAsLinks: Set<String> = Set(classified.compactMap {
            if !$0.wasText, case .link(let url) = $0.item.importItem { return linkKey(url) }
            return nil
        })

        var seenLinks: Set<String> = []
        var seenContent: Set<ContentHash> = []
        var kept: [(index: Int, item: ResolvedShareItem)] = []

        for (index, entry) in classified.enumerated() {
            let item = entry.item
            let isDuplicate: Bool
            switch item.importItem {
            case .link(let url):
                let key = linkKey(url)
                isDuplicate = (entry.wasText && sentAsLinks.contains(key))
                    || !seenLinks.insert(key).inserted
            default:
                if let text = entry.text, !links.isEmpty, isCaption(text, forLinks: links) {
                    isDuplicate = true
                } else if let hash = contentHash(of: item.importItem) {
                    isDuplicate = !seenContent.insert(hash).inserted
                } else {
                    isDuplicate = false
                }
            }

            if isDuplicate {
                item.removeTemporaryFiles()
            } else {
                kept.append((index, item))
            }
        }
        return kept
    }

    // MARK: Helpers

    /// The text an item carries, if it is plain text small enough to be a
    /// caption or an address rather than a document.
    private nonisolated static func sharedText(in item: ImportItem) -> String? {
        switch item {
        case .data(let data, let contentType, _):
            guard contentType.conforms(to: .plainText), data.count <= textInspectionLimit else { return nil }
            return String(data: data, encoding: .utf8)
        case .file(let url, let declaredType):
            let contentType = declaredType
                ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            guard let contentType, contentType.conforms(to: .plainText) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            guard size <= textInspectionLimit, let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8)
        case .link:
            return nil
        }
    }

    /// A web address standing on its own, with nothing else in the text.
    private nonisolated static func loneWebURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    private nonisolated static func isCaption(_ text: String, forLinks links: [String]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let mentioned = webURLs(in: trimmed).map(linkKey)
        if mentioned.contains(where: links.contains) { return true }
        return trimmed.count <= captionLengthLimit && !trimmed.contains(where: \.isNewline)
    }

    private nonisolated static func webURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }

    /// Two spellings of one address — a trailing slash, a different case in
    /// the host — are the same link.
    private nonisolated static func linkKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.hasSuffix("/") { components.path.removeLast() }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private nonisolated static func contentHash(of item: ImportItem) -> ContentHash? {
        switch item {
        case .data(let data, _, _): ContentHash.of(data)
        case .file(let url, _): try? ContentHash.ofFile(at: url)
        case .link: nil
        }
    }
}

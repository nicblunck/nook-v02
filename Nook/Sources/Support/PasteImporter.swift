import Foundation
import UniformTypeIdentifiers
import NookLibrary

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Turns whatever is on the pasteboard into import items.
///
/// Order matters: a copied file is a file, a copied web address is a link, and
/// only then is a copied picture treated as loose bytes. Getting that backwards
/// would turn a copied image *file* into an anonymous blob and lose its name.
@MainActor
enum PasteImporter {

    static func items() -> [ImportItem] {
        #if canImport(AppKit)
        return macItems()
        #elseif canImport(UIKit)
        return phoneItems()
        #else
        return []
        #endif
    }

    /// Whether there is anything worth offering a Paste command for.
    static var hasContent: Bool { !items().isEmpty }

    #if canImport(AppKit)
    private static func macItems() -> [ImportItem] {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            let items = urls.map { url in
                url.isFileURL ? ImportItem.file(url: url) : ImportItem.link(url)
            }
            if !items.isEmpty { return items }
        }

        if let data = pasteboard.data(forType: .png) {
            return [.data(data, contentType: .png, suggestedName: "Pasted Image.png")]
        }
        if let data = pasteboard.data(forType: .tiff) {
            return [.data(data, contentType: .tiff, suggestedName: "Pasted Image.tiff")]
        }
        if let string = pasteboard.string(forType: .string), let url = webURL(from: string) {
            return [.link(url)]
        }
        return []
    }
    #endif

    #if canImport(UIKit) && !targetEnvironment(macCatalyst)
    private static func phoneItems() -> [ImportItem] {
        let pasteboard = UIPasteboard.general

        if pasteboard.hasURLs, let urls = pasteboard.urls, !urls.isEmpty {
            return urls.map { $0.isFileURL ? ImportItem.file(url: $0) : ImportItem.link($0) }
        }
        if pasteboard.hasImages, let images = pasteboard.images {
            return images.enumerated().compactMap { index, image in
                guard let data = image.pngData() else { return nil }
                let name = images.count == 1 ? "Pasted Image.png" : "Pasted Image \(index + 1).png"
                return .data(data, contentType: .png, suggestedName: name)
            }
        }
        if pasteboard.hasStrings, let string = pasteboard.string, let url = webURL(from: string) {
            return [.link(url)]
        }
        return []
    }
    #endif

    /// Only accepts something that is actually a web address, so pasting a
    /// paragraph of text does not silently create a broken link.
    private static func webURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }
}

import Foundation
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import PDFKit
import UIKit
import SwiftUI
import NookLibrary

/// One shared item, resolved and ready to show as a card before it is saved.
///
/// The resolver already copied whatever bytes the system handed over into a
/// file this extension owns, so a preview can be rendered straight from that
/// copy without asking the host app for anything.
struct SharePreviewItem: Identifiable {
    let id: Int
    let resolved: ResolvedShareItem
    let kind: ObjectKind
    let source: String
    var title: String
    var notes: String = ""
    var image: Image?
    var aspectRatio: Double?
    /// Page metadata fetched for a link, carried through to save time so it
    /// can be applied to the object without fetching the page again.
    var linkMetadata: LinkMetadataFetcher.Result?
}

enum SharePreview {

    /// Builds a card's contents: a readable title guessed from whatever the
    /// item carries, and a thumbnail where one can be drawn without importing
    /// the item first.
    static func makeItem(id: Int, resolved: ResolvedShareItem, fallbackName: String) async -> SharePreviewItem {
        switch resolved.importItem {
        case .link(let url):
            let placeholderTitle = url.host() ?? url.absoluteString
            guard let result = await LinkMetadataFetcher.fetch(for: url) else {
                return SharePreviewItem(id: id, resolved: resolved, kind: .link,
                                         source: url.absoluteString,
                                         title: placeholderTitle)
            }
            let fetchedTitle = result.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let (image, aspectRatio) = imageAndAspectRatio(from: result.previewImageData)
            return SharePreviewItem(id: id, resolved: resolved, kind: .link,
                                     source: url.absoluteString,
                                     title: (fetchedTitle?.isEmpty == false ? fetchedTitle! : placeholderTitle),
                                     image: image, aspectRatio: aspectRatio,
                                     linkMetadata: result)

        case .data(_, let contentType, let suggestedName):
            let kind = ObjectKind(contentType: contentType)
            let title = suggestedName.map(titleFromFilename) ?? fallbackName
            return SharePreviewItem(id: id, resolved: resolved, kind: kind,
                                    source: suggestedName ?? fallbackName,
                                    title: title)

        case .file(let url, let declaredType):
            let contentType = declaredType
                ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? .data
            let kind = ObjectKind(contentType: contentType)
            let title = titleFromFilename(url.lastPathComponent)
            let (image, aspectRatio) = await thumbnail(for: url, kind: kind)
            return SharePreviewItem(id: id, resolved: resolved, kind: kind,
                                     source: url.lastPathComponent,
                                     title: title, image: image, aspectRatio: aspectRatio)
        }
    }

    /// A readable title from a filename: extension dropped, separators relaxed.
    private static func titleFromFilename(_ filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        let relaxed = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return relaxed.isEmpty ? filename : relaxed
    }

    private static func thumbnail(for url: URL, kind: ObjectKind) async -> (Image?, Double?) {
        switch kind {
        case .image, .screenshot:
            return imageThumbnail(at: url)
        case .pdf:
            return pdfThumbnail(at: url)
        case .video:
            return await videoThumbnail(at: url)
        case .audio, .file, .link:
            return (nil, nil)
        }
    }

    /// Builds a thumbnail from a link's fetched preview image bytes, the same
    /// way a file's own thumbnail is decoded from disk.
    private static func imageAndAspectRatio(from data: Data?) -> (Image?, Double?) {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return (nil, nil) }
        return (Image(decorative: cgImage, scale: 1), Double(cgImage.width) / Double(cgImage.height))
    }

    private static func imageThumbnail(at url: URL) -> (Image?, Double?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (nil, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return (nil, nil)
        }
        return (Image(decorative: cgImage, scale: 1), Double(cgImage.width) / Double(cgImage.height))
    }

    private static func pdfThumbnail(at url: URL) -> (Image?, Double?) {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return (nil, nil) }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return (nil, nil) }
        let scale = 900 / max(bounds.width, bounds.height)
        let uiImage = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
                                     for: .mediaBox)
        return (Image(uiImage: uiImage), Double(bounds.width / bounds.height))
    }

    /// A frame from the first instant, at the size and orientation the video
    /// actually plays at.
    private static func videoThumbnail(at url: URL) async -> (Image?, Double?) {
        let asset = AVURLAsset(url: url)
        var aspectRatio: Double?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let size = naturalSize.applying(transform)
            if abs(size.height) > 0 {
                aspectRatio = Double(abs(size.width) / abs(size.height))
            }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let (cgImage, _) = try? await generator.image(at: .zero) else {
            return (nil, aspectRatio)
        }
        return (Image(decorative: cgImage, scale: 1),
                aspectRatio ?? Double(cgImage.width) / Double(cgImage.height))
    }
}

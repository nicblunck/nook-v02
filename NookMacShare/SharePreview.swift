import Foundation
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import PDFKit
import AppKit
import SwiftUI
import NookLibrary

/// One attachment, together with what the app it came from called the thing
/// being shared. The share sheet names an item from exactly these two — the
/// rich link the app had already resolved, and the title on the extension item
/// — before it works anything out for itself.
struct SharedAttachment {
    let provider: NSItemProvider
    let sharedTitle: String?

    init(provider: NSItemProvider, sharedTitle: String? = nil) {
        self.provider = provider
        self.sharedTitle = sharedTitle
    }
}

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
    static func makeItem(id: Int,
                         resolved: ResolvedShareItem,
                         fallbackName: String,
                         attachedMetadata: Data? = nil,
                         sharedTitle: String? = nil) async -> SharePreviewItem {
        switch resolved.importItem {
        case .link(let url):
            let known = await LinkMetadataFetcher.metadata(
                for: url,
                attachedMetadata: attachedMetadata,
                sharedTitle: sharedTitle
            )
            let (image, aspectRatio) = imageAndAspectRatio(from: known?.previewImageData)
            return SharePreviewItem(id: id, resolved: resolved, kind: .link,
                                     source: url.absoluteString,
                                     title: LinkNaming.title(pageTitle: known?.metadata.title, url: url),
                                     image: image, aspectRatio: aspectRatio,
                                     linkMetadata: known)

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

        case .color(let hex):
            return SharePreviewItem(id: id, resolved: resolved, kind: .color,
                                    source: hex, title: hex)
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
        case .audio, .file, .link, .color:
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
        let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale),
                                   for: .mediaBox)
        return (Image(nsImage: image), Double(bounds.width / bounds.height))
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

// MARK: - Look

/// The wash the library draws behind its canvas, in the accent the app was
/// given, so a sheet opened from another app still looks like Nook. Plain in
/// Minimal Mode, as the canvas is.
struct ShareBackground: View {
    private let appearance = SharedAppearance()

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            if !appearance.isMinimalMode {
                let accent = Self.color(hex: appearance.accentColorHex) ?? .accentColor
                LinearGradient(colors: [accent.opacity(0.3), accent.opacity(0)],
                               startPoint: .bottom, endPoint: .top)
            }
        }
        .ignoresSafeArea()
    }

    private static func color(hex: String?) -> Color? {
        guard let hex, let number = UInt32(hex.trimmingCharacters(in: .init(charactersIn: "# ")), radix: 16),
              hex.filter(\.isHexDigit).count == 6
        else { return nil }
        return Color(.sRGB,
                     red: Double((number >> 16) & 0xFF) / 255,
                     green: Double((number >> 8) & 0xFF) / 255,
                     blue: Double(number & 0xFF) / 255)
    }
}

/// The tick a save ends on, with where things went, before the sheet closes.
struct ShareConfirmation: View {
    let headline: String

    /// Long enough to read where things went, short enough not to wait on.
    static let duration: Duration = .milliseconds(900)

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
                .frame(height: 52)
            Text(headline)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ShareBackground() }
        .accessibilityElement(children: .combine)
    }
}

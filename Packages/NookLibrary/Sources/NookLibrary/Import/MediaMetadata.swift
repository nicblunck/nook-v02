import Foundation
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import PDFKit

/// Type-specific facts read from a file at import time.
///
/// This is file metadata, kept separate from what the user writes and from
/// anything a model later derives.
struct MediaMetadata: Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?
    var pageCount: Int?
    var creationDate: Date?
}

enum MediaMetadataReader {

    static func read(from url: URL, kind: ObjectKind) async -> MediaMetadata {
        var metadata = MediaMetadata()
        metadata.creationDate = fileCreationDate(of: url)

        switch kind {
        case .image, .screenshot:
            readImage(at: url, into: &metadata)
        case .video, .audio:
            await readAVAsset(at: url, into: &metadata)
        case .pdf:
            readPDF(at: url, into: &metadata)
        case .link, .file:
            break
        }
        return metadata
    }

    private static func fileCreationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private static func readImage(at url: URL, into metadata: inout MediaMetadata) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return }

        if let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            let dimensions = orientedPixelDimensions(width: width, height: height,
                                                     orientation: orientation)
            metadata.pixelWidth = dimensions.width
            metadata.pixelHeight = dimensions.height
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let parsed = exifDateFormatter.date(from: original) {
            metadata.creationDate = parsed
        }
    }

    /// ImageIO reports encoded pixel dimensions before EXIF orientation is
    /// applied. Orientations 5 through 8 rotate the displayed image by a
    /// quarter turn, so its layout width and height must trade places.
    static func orientedPixelDimensions(
        width: Int,
        height: Int,
        orientation: Int?
    ) -> (width: Int, height: Int) {
        guard let orientation, (5...8).contains(orientation) else {
            return (width, height)
        }
        return (height, width)
    }

    private static func readAVAsset(at url: URL, into metadata: inout MediaMetadata) async {
        let asset = AVURLAsset(url: url)

        if let duration = try? await asset.load(.duration),
           duration.isValid, !duration.isIndefinite {
            metadata.duration = CMTimeGetSeconds(duration)
        }

        // A video track's stored size ignores rotation, so the display size is
        // only correct once the preferred transform is applied.
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let size = naturalSize.applying(transform)
            metadata.pixelWidth = Int(abs(size.width))
            metadata.pixelHeight = Int(abs(size.height))
        }
    }

    private static func readPDF(at url: URL, into metadata: inout MediaMetadata) {
        guard let document = PDFDocument(url: url) else { return }
        metadata.pageCount = document.pageCount
        if let page = document.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            metadata.pixelWidth = Int(bounds.width)
            metadata.pixelHeight = Int(bounds.height)
        }
        if let attributes = document.documentAttributes,
           let created = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date {
            metadata.creationDate = created
        }
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()
}

enum ImportClassifier {

    /// Distinguishes a screenshot from an ordinary image. UTI cannot tell them
    /// apart, so this leans on the naming the capturing OS uses.
    static func kind(forContentType contentType: UTType?, filename: String?) -> ObjectKind {
        guard let contentType else { return .file }
        let kind = ObjectKind(contentType: contentType)
        guard kind == .image, let filename else { return kind }
        return isScreenshotName(filename) ? .screenshot : .image
    }

    static func isScreenshotName(_ filename: String) -> Bool {
        let name = filename.lowercased()
        let markers = ["screenshot", "screen shot", "cleanshot", "bildschirmfoto", "capture d’écran", "capture d'écran"]
        return markers.contains { name.hasPrefix($0) || name.contains($0) }
    }

    /// A readable title from a filename: extension dropped, separators relaxed.
    static func title(fromFilename filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        let relaxed = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return relaxed.isEmpty ? filename : relaxed
    }
}

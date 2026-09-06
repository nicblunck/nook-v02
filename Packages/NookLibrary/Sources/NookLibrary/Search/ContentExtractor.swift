import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Pulls readable text out of an original.
///
/// Deliberately simple to begin with: PDFs and plain text. It exists this
/// early because everything downstream — content search, Siri, the MCP
/// adapter, on-device summarisation — reads from the same derived store, and
/// retrofitting that later would mean reprocessing the whole library.
enum ContentExtractor {

    /// Whether this kind of object has text worth trying to extract.
    static func canExtract(kind: ObjectKind, contentType: UTType?) -> Bool {
        switch kind {
        case .pdf: true
        case .file: contentType?.conforms(to: .text) ?? false
        case .image, .screenshot, .video, .audio, .link: false
        }
    }

    /// Extracted text, or nil when there is none to be had. Never throws on a
    /// malformed file: a document that cannot be read is simply one without
    /// extracted text, not a failed import.
    static func extractText(from url: URL, kind: ObjectKind, contentType: UTType?) -> String? {
        let text: String?
        switch kind {
        case .pdf:
            text = PDFDocument(url: url)?.string
        case .file where contentType?.conforms(to: .text) == true:
            text = try? String(contentsOf: url, encoding: .utf8)
        default:
            text = nil
        }

        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Identifies the pipeline that produced a result, so stale output can be
    /// found and regenerated when the extractor changes.
    static let identifier = "text.v1"
}

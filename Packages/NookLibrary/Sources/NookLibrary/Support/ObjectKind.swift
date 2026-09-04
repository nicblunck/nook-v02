import Foundation
import UniformTypeIdentifiers

/// The coarse type of an object, used for the media-type views and for
/// choosing a preview presentation. Every object has exactly one.
public enum ObjectKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case image
    case video
    case audio
    case pdf
    case screenshot
    case link
    case file

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .screenshot: "Screenshot"
        case .link: "Link"
        case .file: "File"
        }
    }

    public var pluralDisplayName: String {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .pdf: "PDFs"
        case .screenshot: "Screenshots"
        case .link: "Links"
        case .file: "Files"
        }
    }

    public var symbolName: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .screenshot: "camera.viewfinder"
        case .link: "link"
        case .file: "doc"
        }
    }

    /// Kinds that appear as their own media-type view in the sidebar.
    public static let mediaTypes: [ObjectKind] = [.image, .video, .audio, .pdf, .link, .screenshot]

    /// Classifies a content type. Screenshots are distinguished separately at
    /// import time, since UTI alone cannot tell one from an ordinary image.
    public init(contentType: UTType) {
        if contentType.conforms(to: .pdf) {
            self = .pdf
        } else if contentType.conforms(to: .image) {
            self = .image
        } else if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
            self = .video
        } else if contentType.conforms(to: .audio) {
            self = .audio
        } else {
            self = .file
        }
    }
}

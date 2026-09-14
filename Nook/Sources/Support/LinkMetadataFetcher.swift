import Foundation
import ImageIO
import LinkPresentation
import UniformTypeIdentifiers
import NookLibrary

/// Fetches the title, description and preview picture for a saved link.
///
/// The library stays out of networking: it holds what a link is, and this
/// hands it what the page said about itself. The page is not archived — only
/// enough to recognise the link later.
enum LinkMetadataFetcher {

    struct Result: Sendable {
        var metadata: NookLibrary.LinkMetadata
        var previewImageData: Data?
    }

    static func fetch(for url: URL, timeout: Duration = .seconds(10)) async -> Result? {
        let provider = LPMetadataProvider()
        provider.timeout = TimeInterval(timeout.components.seconds)

        guard let fetched = try? await provider.startFetchingMetadata(for: url) else { return nil }

        // Some pages offer only a favicon. It is still a more useful local
        // preview than the generic link glyph.
        let previewProvider = fetched.imageProvider ?? fetched.iconProvider
        let previewImageData = await imageData(from: previewProvider)
        let previewDimensions = previewImageData.flatMap(imageDimensions)

        let metadata = NookLibrary.LinkMetadata(
            title: fetched.title,
            summary: fetched.value(forKey: "summary") as? String,
            // LinkPresentation does not expose the remote image URL. Keeping
            // the page URL here records that an image provider existed, which
            // lets another device rebuild its disposable thumbnail cache.
            previewImageURL: previewProvider != nil ? url : nil,
            faviconURL: fetched.iconProvider != nil ? url : nil,
            previewPixelWidth: previewDimensions?.width,
            previewPixelHeight: previewDimensions?.height
        )
        return Result(metadata: metadata, previewImageData: previewImageData)
    }

    /// Loads the concrete representation the provider actually advertises.
    /// Asking iOS for the abstract `public.image` type can return no bytes even
    /// when the same provider vends a JPEG, PNG, HEIC, or platform image.
    static func imageData(from provider: NSItemProvider?) async -> Data? {
        guard let provider else { return nil }

        let concreteImageTypes = provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .filter { $0.conforms(to: .image) }

        for type in concreteImageTypes {
            if let data = await dataRepresentation(from: provider, type: type) {
                return data
            }
        }

        // A provider can advertise only a parent type and coerce its concrete
        // representation on request, so retain the broad fallback.
        return await dataRepresentation(from: provider, type: .image)
    }

    private static func dataRepresentation(from provider: NSItemProvider, type: UTType) async -> Data? {
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func imageDimensions(in data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        guard let orientation, (5...8).contains(orientation) else {
            return (width, height)
        }
        return (height, width)
    }
}

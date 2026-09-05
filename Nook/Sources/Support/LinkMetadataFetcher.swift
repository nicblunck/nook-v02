import Foundation
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

        let metadata = NookLibrary.LinkMetadata(
            title: fetched.title,
            summary: fetched.value(forKey: "summary") as? String,
            previewImageURL: fetched.imageProvider != nil ? url : nil,
            faviconURL: fetched.iconProvider != nil ? url : nil
        )
        return Result(metadata: metadata, previewImageData: await imageData(from: fetched))
    }

    private static func imageData(from metadata: LPLinkMetadata) async -> Data? {
        guard let provider = metadata.imageProvider else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

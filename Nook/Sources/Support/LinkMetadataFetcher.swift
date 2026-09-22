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

        /// Keeps what is already known and takes the rest from a second
        /// source. The picture and its dimensions move together: a size read
        /// from one image must never be attached to a different one.
        func filling(gapsFrom other: Self) -> Self {
            var merged = self
            merged.metadata.title = metadata.title ?? other.metadata.title
            merged.metadata.summary = metadata.summary ?? other.metadata.summary
            merged.metadata.faviconURL = metadata.faviconURL ?? other.metadata.faviconURL
            if previewImageData == nil {
                merged.previewImageData = other.previewImageData
                merged.metadata.previewImageURL = other.metadata.previewImageURL
                merged.metadata.previewPixelWidth = other.metadata.previewPixelWidth
                merged.metadata.previewPixelHeight = other.metadata.previewPixelHeight
            }
            return merged
        }
    }

    /// What a sharing app registers when it has already worked out what a link
    /// is — the same object the share sheet drew its own header from.
    static let attachedMetadataTypeIdentifier = "com.apple.linkpresentation.metadata"

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
            title: LinkNaming.normalized(fetched.title),
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

    /// Everything known about a shared link, resolved the way the share sheet
    /// resolves it.
    ///
    /// What the sharing app handed over wins: it is what the person saw in the
    /// share sheet a moment ago, and working the same link out twice is how two
    /// saves of one page end up under two different names. The page is still
    /// asked when the handover left something out — a description and a picture
    /// are what make a saved link recognisable later.
    static func metadata(for url: URL,
                         attachedMetadata: Data? = nil,
                         sharedTitle: String? = nil) async -> Result? {
        var known: Result?
        if let attachedMetadata {
            known = await attached(attachedMetadata, for: url)
        }

        if LinkNaming.normalized(known?.metadata.title) == nil,
           let sharedTitle = LinkNaming.normalized(sharedTitle) {
            var named = known ?? Result(metadata: NookLibrary.LinkMetadata())
            named.metadata.title = sharedTitle
            known = named
        }

        if let known, known.metadata.title != nil, known.previewImageData != nil {
            return known
        }

        guard let fetched = await fetch(for: url) else { return known }
        guard let known else { return fetched }
        return known.filling(gapsFrom: fetched)
    }

    /// The bytes of the rich link a sharing app attached to what it shared, if
    /// it attached one at all.
    ///
    /// Reading stays on the main actor, where the extension's providers live,
    /// and only the bytes leave.
    @MainActor
    static func attachedMetadataData(from provider: NSItemProvider) async -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(attachedMetadataTypeIdentifier) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: attachedMetadataTypeIdentifier
            ) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// Unpacks a handed-over link into the same shape a fetch produces, so the
    /// rest of the save path cannot tell which one it got.
    static func attached(_ data: Data, for url: URL) async -> Result? {
        guard let attached = decodeAttachedMetadata(data) else { return nil }

        let previewProvider = attached.imageProvider ?? attached.iconProvider
        let previewImageData = await imageData(from: previewProvider)
        let previewDimensions = previewImageData.flatMap(imageDimensions)

        let metadata = NookLibrary.LinkMetadata(
            title: LinkNaming.normalized(attached.title),
            summary: attached.value(forKey: "summary") as? String,
            previewImageURL: previewProvider != nil ? url : nil,
            faviconURL: attached.iconProvider != nil ? url : nil,
            previewPixelWidth: previewDimensions?.width,
            previewPixelHeight: previewDimensions?.height
        )
        return Result(metadata: metadata, previewImageData: previewImageData)
    }

    /// Sharing apps archive their metadata with whichever coder they were
    /// written against, so a strict decode is tried first and a lenient one
    /// only if it fails.
    private static func decodeAttachedMetadata(_ data: Data) -> LPLinkMetadata? {
        if let metadata = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: LPLinkMetadata.self, from: data
        ) {
            return metadata
        }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(of: LPLinkMetadata.self,
                                       forKey: NSKeyedArchiveRootObjectKey)
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

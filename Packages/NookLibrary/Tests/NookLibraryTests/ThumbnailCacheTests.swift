import Foundation
import CoreGraphics
import Testing
@testable import NookLibrary

/// The cache exists so that scrolling and resizing a wall of pictures draws
/// from what was already made, rather than asking Quick Look again for every
/// card at every slider position.
@Suite("Thumbnail cache")
struct ThumbnailCacheTests {

    @Test("Requests round up to one of three rendering sizes, capped at the largest")
    func roundsRequestsToFixedSizes() {
        #expect(ThumbnailStore.renderSize(for: 128) == 256)
        #expect(ThumbnailStore.renderSize(for: 256) == 256)
        #expect(ThumbnailStore.renderSize(for: 257) == 512)
        #expect(ThumbnailStore.renderSize(for: 420) == 512)
        #expect(ThumbnailStore.renderSize(for: 840) == 1024)
        #expect(ThumbnailStore.renderSize(for: 1536) == 1024)
    }

    @Test("A rendering is named by content and size step under the new scheme")
    func namesRenderingsByStep() throws {
        let hash = try #require(ContentHash(hexValue: String(repeating: "ab", count: 32)))
        #expect(ThumbnailStore.renderedKey(for: hash, size: 512) == "v2-\(hash.hexValue)-512")
    }

    @Test("Only renderings named under the old scheme are swept up")
    func recognisesLegacyRenderings() {
        let hex = String(repeating: "0f", count: 32)
        #expect(ThumbnailStore.isLegacyRendering("\(hex)-1260.png"))
        #expect(!ThumbnailStore.isLegacyRendering("v2-\(hex)-512.thumb"))
        #expect(!ThumbnailStore.isLegacyRendering("synced-\(hex).thumb"))
        #expect(!ThumbnailStore.isLegacyRendering("link-\(UUID().uuidString).png"))
    }

    @Test("Opaque pictures are saved as JPEG, transparent ones as PNG")
    func choosesFormatByTransparency() throws {
        let opaque = try #require(Self.image(alpha: 1))
        let transparent = try #require(Self.image(alpha: 0))

        let jpeg = try #require(ThumbnailStore.encodedForDisk(opaque))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))

        let png = try #require(ThumbnailStore.encodedForDisk(transparent))
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("A picture once loaded is in memory for every request it can serve")
    func servesNeighbouringSizesFromMemory() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeImageFile(named: "wall.png")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)
        let snapshot = try #require(await harness.service.object(id))

        let directory = try harness.makeDirectory()
        let store = try ThumbnailStore(directory: directory)
        await store.attach(blobStore: harness.library.blobStore)

        #expect(store.cachedImage(for: snapshot, maximumSize: 420) == nil)
        let loaded = try #require(await store.image(for: snapshot, maximumSize: 420))
        #expect(!loaded.isBorrowed)
        #expect(abs(loaded.aspectRatio - 1) < 0.01)
        #expect(loaded.traits.predominantColor != nil)

        // Two slider positions that round to the same step share the picture,
        // and a smaller request is happy with the larger one already decoded.
        #expect(store.cachedImage(for: snapshot, maximumSize: 300) != nil)
        #expect(store.cachedImage(for: snapshot, maximumSize: 128) != nil)
        #expect(store.cachedImage(for: snapshot, maximumSize: 1024) == nil)

        let blob = try #require(snapshot.blob)
        let saved = directory.appending(path: "\(ThumbnailStore.renderedKey(for: blob.hash, size: 512)).thumb")
        #expect(FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)))

        store.evictCachedImages(for: snapshot)
        #expect(store.cachedImage(for: snapshot, maximumSize: 420) == nil)
        // Read back from disk rather than rendered again.
        #expect(await store.image(for: snapshot, maximumSize: 420) != nil)
        #expect(store.cachedImage(for: snapshot, maximumSize: 420) != nil)
    }

    @Test("Clearing the store forgets the pictures in memory too")
    func clearEmptiesMemory() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeImageFile(named: "wall.png")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)
        let snapshot = try #require(await harness.service.object(id))

        let store = try ThumbnailStore(directory: try harness.makeDirectory())
        await store.attach(blobStore: harness.library.blobStore)
        _ = try #require(await store.image(for: snapshot))
        try await store.clear()
        #expect(store.cachedImage(for: snapshot) == nil)
    }

    /// A small square filled with one colour at the given opacity.
    private static func image(alpha: CGFloat) -> CGImage? {
        let side = 16
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}

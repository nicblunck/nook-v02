import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NookLibrary

/// A throwaway library plus a scratch directory for source files, so each test
/// starts from nothing and leaves nothing behind.
struct TestLibrary {
    let library: Library
    let scratch: URL

    init() async throws {
        library = try await Library.inMemory()
        scratch = URL.temporaryDirectory.appending(path: "NookTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    var service: LibraryService { library.service }

    /// Writes a file outside the library, to be imported.
    func makeSourceFile(named name: String, contents: String) throws -> URL {
        let url = scratch.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Writes a small opaque PNG outside the library — something Quick Look
    /// will genuinely render, so thumbnail tests exercise the real generator.
    func makeImageFile(named name: String, side: Int = 64) throws -> URL {
        let url = scratch.appending(path: name)
        let context = try #require(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try #require(context.makeImage())

        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// A scratch directory of its own, for a store built by hand.
    func makeDirectory() throws -> URL {
        let url = scratch.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: scratch)
    }
}


/// A blob store that has heard of every blob and holds none of them — the Mac,
/// moments after something was saved on the phone.
actor AbsentBlobStore: BlobStore {
    func ingest(contentsOf url: URL, contentType: UTType?) async throws -> BlobDescriptor {
        throw BlobStoreError.unreadableSource(url)
    }

    func ingest(data: Data, contentType: UTType?) async throws -> BlobDescriptor {
        throw BlobStoreError.writeFailed(underlying: "read-only stub")
    }

    nonisolated func localURL(for descriptor: BlobDescriptor) -> URL? { nil }

    nonisolated func isAvailableLocally(_ descriptor: BlobDescriptor) -> Bool { false }

    func materialize(_ descriptor: BlobDescriptor) async throws -> URL {
        throw BlobStoreError.notFound(descriptor.hash)
    }

    func read(_ descriptor: BlobDescriptor) async throws -> Data {
        throw BlobStoreError.notFound(descriptor.hash)
    }

    func evict(_ descriptor: BlobDescriptor) async throws {}
}

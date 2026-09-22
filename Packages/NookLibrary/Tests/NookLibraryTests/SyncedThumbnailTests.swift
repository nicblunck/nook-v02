import Foundation
import Testing
import UniformTypeIdentifiers
@testable import NookLibrary

/// The gap these close: records reach another device over CloudKit while the
/// originals they describe travel over iCloud Drive, so for a while a device
/// knows an item exists and has no way to draw it.
@Suite("Synced thumbnails")
struct SyncedThumbnailTests {

    @Test("A picture is produced for an imported original, ready to travel")
    func producesTravellingThumbnail() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeImageFile(named: "wall.png")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)

        #expect(await harness.service.objectsAwaitingThumbnailSync() == [id])
        #expect(try await harness.service.syncedThumbnailData(for: id) == nil)

        await harness.service.generatePendingSyncedThumbnails(using: harness.library.thumbnails)

        let data = try #require(try await harness.service.syncedThumbnailData(for: id))
        #expect(!data.isEmpty)
        #expect(data.count <= ThumbnailStore.syncedMaximumByteCount)
    }

    @Test("Every original is asked about exactly once, renderable or not")
    func doesNotReaskAfterAPass() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let image = try harness.makeImageFile(named: "wall.png")
        let opaque = try harness.makeSourceFile(named: "mystery.bin", contents: "\u{0}\u{1}\u{2}")
        _ = await harness.service.importItems(
            [.file(url: image), .file(url: opaque)], into: .root
        )

        #expect(await harness.service.objectsAwaitingThumbnailSync().count == 2)
        await harness.service.generatePendingSyncedThumbnails(using: harness.library.thumbnails)

        // Whether Quick Look found something or not, the question is settled:
        // a record with no payload is a tombstone, and every device honours it.
        #expect(await harness.service.objectsAwaitingThumbnailSync().isEmpty)
    }

    @Test("A link carries no travelling picture: it has no original to render")
    func skipsObjectsWithoutAnOriginal() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        _ = try await harness.service.importLink(
            #require(URL(string: "https://example.com")), into: .root
        )
        #expect(await harness.service.objectsAwaitingThumbnailSync().isEmpty)
    }

    @Test("A travelling picture is protected exactly as the original is")
    func honoursLocks() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let folder = try await harness.service.createFolder(named: "Finances")
        let source = try harness.makeImageFile(named: "payslip.png")
        let report = await harness.service.importItems(
            [.file(url: source)], into: .folder(folder.id)
        )
        let id = try #require(report.importedIDs.first)
        await harness.service.generatePendingSyncedThumbnails(using: harness.library.thumbnails)
        #expect(try await harness.service.syncedThumbnailData(for: id) != nil)

        try await harness.service.setPrivacy(PrivacyFlags(isLocked: true), forFolder: folder.id)

        await #expect(throws: LibraryError.self) {
            _ = try await harness.service.syncedThumbnailData(for: id)
        }

        let authenticated = AccessContext().unlocking(.folder(folder.id))
        #expect(try await harness.service.syncedThumbnailData(for: id, in: authenticated) != nil)
    }

    @Test("A device without the original shows the picture that travelled to it")
    func servesTravellingPictureWhenOriginalIsAbsent() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeImageFile(named: "wall.png")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)
        let snapshot = try #require(await harness.service.object(id))

        let store = try ThumbnailStore(directory: try harness.makeDirectory())
        await store.attach(blobStore: AbsentBlobStore())
        let travelled = Data("a picture from the phone".utf8)
        await store.attach(syncedThumbnailProvider: { requested in
            requested == id ? travelled : nil
        })

        #expect(await store.thumbnail(for: snapshot) == travelled)
        // Served from its own cache the second time, without asking again.
        await store.attach(syncedThumbnailProvider: { _ in nil })
        #expect(await store.thumbnail(for: snapshot) == travelled)
    }

    @Test("Once the original arrives the device renders its own picture instead")
    func upgradesToALocalRenderingWhenTheOriginalArrives() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeImageFile(named: "wall.png")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)
        let snapshot = try #require(await harness.service.object(id))

        let store = try ThumbnailStore(directory: try harness.makeDirectory())
        await store.attach(blobStore: harness.library.blobStore)
        let travelled = Data("a picture from the phone".utf8)
        await store.attach(syncedThumbnailProvider: { _ in travelled })

        let rendered = try #require(await store.thumbnail(for: snapshot))
        #expect(rendered != travelled)
    }

    @Test("A borrowed picture still beats a glyph when nothing can be rendered")
    func fallsBackToTheTravellingPictureWhenRenderingFails() async throws {
        let harness = try await TestLibrary()
        defer { harness.cleanUp() }

        let source = try harness.makeImageFile(named: "wall.png")
        let report = await harness.service.importItems([.file(url: source)], into: .root)
        let id = try #require(report.importedIDs.first)
        let snapshot = try #require(await harness.service.object(id))

        // Claims to hold the original, then cannot produce it — a download
        // that reported success and left nothing behind.
        let store = try ThumbnailStore(directory: try harness.makeDirectory())
        await store.attach(blobStore: LyingBlobStore())
        let travelled = Data("a picture from the phone".utf8)
        await store.attach(syncedThumbnailProvider: { _ in travelled })

        #expect(await store.thumbnail(for: snapshot) == travelled)
        #expect(id == snapshot.id)
    }
}

/// Reports every blob as present and produces none of them.
private actor LyingBlobStore: BlobStore {
    func ingest(contentsOf url: URL, contentType: UTType?) async throws -> BlobDescriptor {
        throw BlobStoreError.unreadableSource(url)
    }

    func ingest(data: Data, contentType: UTType?) async throws -> BlobDescriptor {
        throw BlobStoreError.writeFailed(underlying: "read-only stub")
    }

    nonisolated func localURL(for descriptor: BlobDescriptor) -> URL? { nil }

    nonisolated func isAvailableLocally(_ descriptor: BlobDescriptor) -> Bool { true }

    func materialize(_ descriptor: BlobDescriptor) async throws -> URL {
        throw BlobStoreError.notFound(descriptor.hash)
    }

    func read(_ descriptor: BlobDescriptor) async throws -> Data {
        throw BlobStoreError.notFound(descriptor.hash)
    }

    func evict(_ descriptor: BlobDescriptor) async throws {}
}

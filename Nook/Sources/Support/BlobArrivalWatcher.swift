import Foundation
import NookLibrary

/// Watches the iCloud container the originals live in, and says when its
/// contents change.
///
/// Originals and metadata reach a device over two different systems: records
/// arrive over CloudKit, bytes over iCloud Drive. Nothing connects them, so
/// without a watcher the app learns that an original has appeared only by
/// asking — and it asks only when a tile happens to be drawn. An item saved on
/// the phone would sit under a placeholder glyph on the Mac until something
/// rebuilt its tile.
///
/// A file appearing here is not the same as its bytes being present: iCloud
/// publishes a placeholder first and downloads on demand. Both are worth
/// hearing about. The placeholder is what lets a download be *started* at all,
/// and the completed download is what lets a full-quality thumbnail replace
/// the small one that travelled with the metadata.
@MainActor
final class BlobArrivalWatcher {
    /// Posted when originals appear in, or finish downloading to, this device.
    static let blobsDidChange = Notification.Name("Nook.blobsDidChange")

    private let query = NSMetadataQuery()
    private var observers: [any NSObjectProtocol] = []
    private var coalesceTask: Task<Void, Never>?

    /// Updates arrive one file at a time during a large sync. Refreshing on
    /// each one would rebuild every visible tile dozens of times for no gain,
    /// so they are gathered into one notification.
    private static let coalescingWindow = Duration.milliseconds(750)

    init?(locations: LibraryLocations) {
        // No ubiquitous container means no second sync system to reconcile:
        // the originals are already wherever they are going to be.
        guard locations.cloudRoot != nil else { return nil }

        // Originals live beside, not inside, the container's Documents
        // directory, which is the scope that covers them. Nothing else of ours
        // is kept there, so every item the query sees is an original.
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")

        for name in [
            NSNotification.Name.NSMetadataQueryDidFinishGathering,
            NSNotification.Name.NSMetadataQueryDidUpdate
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: query,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleNotification() }
            }
            observers.append(observer)
        }

        query.start()
    }

    isolated deinit {
        query.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func scheduleNotification() {
        coalesceTask?.cancel()
        coalesceTask = Task { [window = Self.coalescingWindow] in
            guard (try? await Task.sleep(for: window)) != nil else { return }
            NotificationCenter.default.post(name: Self.blobsDidChange, object: nil)
        }
    }
}

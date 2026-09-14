import Foundation
import UniformTypeIdentifiers

/// An import resolved from an item provider, plus any short-lived file that
/// should be removed after the library has copied its contents.
public struct ResolvedShareItem: Sendable {
    public let importItem: ImportItem

    private let temporaryDirectoryURL: URL?

    init(importItem: ImportItem, temporaryDirectoryURL: URL? = nil) {
        self.importItem = importItem
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    public func removeTemporaryFiles() {
        guard let temporaryDirectoryURL else { return }
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }
}

/// Converts attachments from a system Share extension into Nook imports.
///
/// NSItemProvider is process-bound and not Sendable, so resolution stays on
/// the main actor. Only values and copied temporary files leave this boundary.
@MainActor
public enum ShareItemResolver {
    public static func displayName(for provider: NSItemProvider) -> String {
        if let suggestedName = provider.suggestedName, !suggestedName.isEmpty {
            return suggestedName
        }

        return provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first(where: { $0 != .item })?
            .localizedDescription ?? "Item"
    }

    public static func resolve(_ provider: NSItemProvider) async -> ResolvedShareItem? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await provider.loadSharedURL(),
           !url.isFileURL {
            return ResolvedShareItem(importItem: .link(url))
        }

        let contentTypes = provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .filter { $0 != .url && $0 != .fileURL }

        for contentType in contentTypes {
            if let copiedFile = try? await provider.copyFileRepresentation(for: contentType) {
                return ResolvedShareItem(
                    importItem: .file(url: copiedFile.fileURL, contentType: contentType),
                    temporaryDirectoryURL: copiedFile.temporaryDirectoryURL
                )
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let data = try? await provider.loadSharedData(for: .plainText) {
            return ResolvedShareItem(
                importItem: .data(
                    data,
                    contentType: .plainText,
                    suggestedName: provider.suggestedName ?? "Shared Text.txt"
                )
            )
        }

        if let copiedFile = try? await provider.copyFileRepresentation(for: .item) {
            return ResolvedShareItem(
                importItem: .file(url: copiedFile.fileURL),
                temporaryDirectoryURL: copiedFile.temporaryDirectoryURL
            )
        }

        return nil
    }
}

@MainActor
private extension NSItemProvider {
    struct CopiedFile: Sendable {
        let fileURL: URL
        let temporaryDirectoryURL: URL
    }

    func loadSharedURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.url.identifier) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let url: URL?
                switch item {
                case let value as URL:
                    url = value
                case let value as NSURL:
                    url = value as URL
                case let value as String:
                    url = URL(string: value)
                case let value as Data:
                    url = String(data: value, encoding: .utf8).flatMap(URL.init(string:))
                default:
                    url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    func loadSharedData(for type: UTType) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// The system-owned URL is valid only during the completion handler, so
    /// copy it before resuming the awaiting import.
    func copyFileRepresentation(for type: UTType) async throws -> CopiedFile? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                let temporaryDirectory = URL.temporaryDirectory
                    .appending(path: "NookShare-\(UUID().uuidString)", directoryHint: .isDirectory)
                let filename = url.lastPathComponent.isEmpty
                    ? "Shared Item"
                    : url.lastPathComponent
                let destination = temporaryDirectory.appending(path: filename)

                do {
                    try FileManager.default.createDirectory(
                        at: temporaryDirectory,
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(
                        returning: CopiedFile(
                            fileURL: destination,
                            temporaryDirectoryURL: temporaryDirectory
                        )
                    )
                } catch {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

import Foundation
import CryptoKit

/// A SHA-256 digest of a blob's bytes, used both to address stored content and
/// to recognise a byte-identical import.
public struct ContentHash: Hashable, Sendable, Codable, CustomStringConvertible {
    public let hexValue: String

    public init?(hexValue: String) {
        let normalized = hexValue.lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy({ $0.isHexDigit })
        else { return nil }
        self.hexValue = normalized
    }

    private init(unchecked hexValue: String) {
        self.hexValue = hexValue
    }

    public var description: String { hexValue }

    /// First two byte-pairs, used to fan blobs across subdirectories so no
    /// single directory accumulates the whole library.
    public var shardComponents: [String] {
        [String(hexValue.prefix(2)), String(hexValue.dropFirst(2).prefix(2))]
    }

    public static func of(_ data: Data) -> ContentHash {
        ContentHash(unchecked: SHA256.hash(data: data).hexString)
    }

    /// Hashes a file in chunks so that importing a large video does not read
    /// the whole thing into memory.
    public static func ofFile(at url: URL, chunkSize: Int = 1 << 20) throws -> ContentHash {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return ContentHash(unchecked: hasher.finalize().hexString)
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

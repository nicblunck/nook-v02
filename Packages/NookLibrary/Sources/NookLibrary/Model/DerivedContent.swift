import Foundation
import SwiftData

/// The category of a machine-produced representation.
public enum DerivedContentKind: String, Codable, Sendable, CaseIterable {
    case extractedText
    case ocrText
    case transcript
    case aiDescription
    case embedding
}

/// A representation the app produced from an object, kept strictly apart from
/// user metadata and file metadata.
///
/// Everything here is rebuildable and disposable. It never forms part of the
/// immutable original, it can be regenerated after deletion, and heavy or
/// device-specific results can stay local rather than syncing.
@Model
public final class DerivedContent {
    public var identifier: UUID = UUID()
    public var kindRaw: String = DerivedContentKind.extractedText.rawValue
    public var textValue: String?
    public var dataValue: Data?
    public var generatedAt: Date = Date.distantPast
    /// Identifies the extractor or model that produced this, so stale results
    /// can be found and regenerated when the pipeline changes.
    public var generatorIdentifier: String?
    /// When true this record stays on the device that produced it.
    public var isDeviceLocal: Bool = true

    public var object: LibraryObject?

    public init(
        identifier: UUID = UUID(),
        kind: DerivedContentKind,
        object: LibraryObject?,
        textValue: String? = nil,
        dataValue: Data? = nil,
        generatorIdentifier: String? = nil,
        generatedAt: Date = .now,
        isDeviceLocal: Bool = true
    ) {
        self.identifier = identifier
        self.kindRaw = kind.rawValue
        self.object = object
        self.textValue = textValue
        self.dataValue = dataValue
        self.generatorIdentifier = generatorIdentifier
        self.generatedAt = generatedAt
        self.isDeviceLocal = isDeviceLocal
    }

    public var kind: DerivedContentKind {
        get { DerivedContentKind(rawValue: kindRaw) ?? .extractedText }
        set { kindRaw = newValue.rawValue }
    }
}

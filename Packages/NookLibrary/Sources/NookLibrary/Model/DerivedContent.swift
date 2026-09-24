import Foundation
import SwiftData

/// The category of a machine-produced representation.
public enum DerivedContentKind: String, Codable, Sendable, CaseIterable {
    case extractedText
    case ocrText
    case transcript
    case aiDescription
    case embedding
    /// A small rendering of the object, produced once by whichever device
    /// holds the original and carried to the others alongside the metadata.
    /// Its bytes live in `dataValue`; a record with none is a tombstone
    /// meaning there was nothing renderable, so no device asks again.
    case thumbnail
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
    /// Whether this result is meant to stay on the device that produced it.
    /// Descriptive for now — every model in the schema mirrors to CloudKit —
    /// but it marks which records are cheap to carry and which are not, and
    /// it is what a future device-local store would filter on.
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

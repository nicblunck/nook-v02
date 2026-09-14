import Foundation

/// How a location presents its contents.
public enum LibraryViewMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Dense and metadata-oriented; suits documents, audio and large mixed libraries.
    case list
    /// Even thumbnails at a regular size; suits mixed content with equal weighting.
    case grid
    /// Variable-height columns; suits images, screenshots and mixed aspect ratios.
    case masonry

    public var id: String { rawValue }

    /// Whether the layout has an item size worth changing. A list row is as
    /// tall as its text and has nothing to resize.
    public var resizesItems: Bool { self != .list }

    public var displayName: String {
        switch self {
        case .list: "List"
        case .grid: "Icon Grid"
        case .masonry: "Masonry Grid"
        }
    }

    public var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        case .masonry: "rectangle.3.offgrid"
        }
    }
}

/// When masonry items show the caption that identifies them.
///
/// Automatic follows the platform's input model: it appears as a hover
/// overlay on macOS and as an attached section on touch devices.
public enum MasonryCaptionDisplay: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic
    case always
    case hidden

    public var id: Self { self }
}

/// The presentation settings for one location.
///
/// Held together in one value because "remember this location" has to capture
/// the whole arrangement the user was looking at, not one setting at a time.
public struct LocationViewPreferences: Hashable, Sendable, Codable {
    public var viewMode: LibraryViewMode
    public var sort: ObjectSort
    public var foldersFirst: Bool
    public var masonryCaptionDisplay: MasonryCaptionDisplay
    public var showsMasonryTypeLabels: Bool
    /// How large the items are drawn, as a multiple of each layout's own
    /// natural size. One number rather than one per layout, so making things
    /// bigger in the icon grid leaves them bigger on the masonry wall: the
    /// user is saying how close they want to be, not sizing a particular view.
    public var itemScale: Double

    /// Small enough to take in a folder at a glance, large enough to read a
    /// screenshot without opening it.
    public static let itemScaleRange: ClosedRange<Double> = 0.5...3

    public static func clamped(scale: Double) -> Double {
        min(max(scale, itemScaleRange.lowerBound), itemScaleRange.upperBound)
    }

    public static let systemDefault = LocationViewPreferences(
        viewMode: .grid,
        sort: .default,
        foldersFirst: true,
        masonryCaptionDisplay: .automatic,
        showsMasonryTypeLabels: true,
        itemScale: 1
    )

    public init(viewMode: LibraryViewMode = .grid,
                sort: ObjectSort = .default,
                foldersFirst: Bool = true,
                masonryCaptionDisplay: MasonryCaptionDisplay = .automatic,
                showsMasonryTypeLabels: Bool = true,
                itemScale: Double = 1) {
        self.viewMode = viewMode
        self.sort = sort
        self.foldersFirst = foldersFirst
        self.masonryCaptionDisplay = masonryCaptionDisplay
        self.showsMasonryTypeLabels = showsMasonryTypeLabels
        self.itemScale = Self.clamped(scale: itemScale)
    }

    /// Decoded a setting at a time, each falling back to the default, so an
    /// arrangement saved before a setting existed still opens — which is what
    /// lets a new one be added without a migration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.systemDefault
        self.init(
            viewMode: try container.decodeIfPresent(LibraryViewMode.self, forKey: .viewMode) ?? fallback.viewMode,
            sort: try container.decodeIfPresent(ObjectSort.self, forKey: .sort) ?? fallback.sort,
            foldersFirst: try container.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? fallback.foldersFirst,
            masonryCaptionDisplay: try container.decodeIfPresent(
                MasonryCaptionDisplay.self,
                forKey: .masonryCaptionDisplay
            ) ?? fallback.masonryCaptionDisplay,
            showsMasonryTypeLabels: try container.decodeIfPresent(
                Bool.self,
                forKey: .showsMasonryTypeLabels
            ) ?? fallback.showsMasonryTypeLabels,
            itemScale: try container.decodeIfPresent(Double.self, forKey: .itemScale) ?? fallback.itemScale
        )
    }
}

extension LocationViewPreferences {
    /// Stored as JSON on the folder or collection, so adding grouping and
    /// density later needs no schema change.
    var encoded: Data? { try? JSONEncoder().encode(self) }

    init?(encoded data: Data?) {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }
}

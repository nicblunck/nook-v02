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
        case .masonry: "rectangle.grid.2x2"
        }
    }
}

/// The presentation settings for one location.
///
/// Held together in one value because "remember this location" has to capture
/// the whole arrangement the user was looking at, not one setting at a time.
public struct LocationViewPreferences: Hashable, Sendable, Codable {
    public var viewMode: LibraryViewMode
    public var sort: ObjectSort
    public var foldersFirst: Bool

    public static let systemDefault = LocationViewPreferences(
        viewMode: .grid, sort: .default, foldersFirst: true
    )

    public init(viewMode: LibraryViewMode = .grid,
                sort: ObjectSort = .default,
                foldersFirst: Bool = true) {
        self.viewMode = viewMode
        self.sort = sort
        self.foldersFirst = foldersFirst
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

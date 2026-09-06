import Foundation
import Observation
import NookLibrary

/// Where the app should go next, when something outside the interface asks.
///
/// An intent, and later a share extension or a Spotlight result, can run
/// before any window is ready. Each leaves a request here and the window picks
/// it up when it appears, so nothing has to reach into view state or assume the
/// app was already running.
@MainActor
@Observable
final class AppNavigator {
    static let shared = AppNavigator()

    enum Request: Equatable {
        case scope(LibraryScope)
        case object(ObjectID)
    }

    private(set) var pending: Request?

    private init() {}

    func request(_ request: Request) {
        pending = request
    }

    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

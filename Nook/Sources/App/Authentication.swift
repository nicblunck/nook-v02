import Foundation
import LocalAuthentication

/// How an authentication attempt ended.
///
/// Cancelling is kept apart from failing because the two deserve different
/// answers: a user who dismissed the prompt has already been told what
/// happened, and does not need an alert repeating it back at them.
enum AuthenticationOutcome: Sendable {
    case succeeded
    case cancelled
    case failed(String)
}

/// Whoever can vouch that the person at the device is the owner.
///
/// The privacy broker takes an `AccessContext` and asks no questions about
/// where it came from, so this is the one place that may raise one. It is a
/// protocol so the app's own tests can answer without a device — and so the
/// answer is always somebody's explicit decision rather than a default.
@MainActor
protocol LibraryAuthenticating {
    func authenticate(reason: String) async -> AuthenticationOutcome
}

/// Face ID, Touch ID, or the device passcode.
///
/// `deviceOwnerAuthentication` is the policy that falls back to the passcode
/// when biometrics are unavailable or have failed, which is what makes hidden
/// content reachable on a Mac without Touch ID as well as on one with it.
struct DeviceAuthenticator: LibraryAuthenticating {
    func authenticate(reason: String) async -> AuthenticationOutcome {
        // A fresh context per request. Reusing one lets an earlier success
        // stand in for a later question, which is exactly what a lock is for.
        let context = LAContext()
        var availability: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availability) else {
            return .failed(availability?.localizedDescription
                ?? "This device has no passcode, Touch ID or Face ID set up.")
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { succeeded, error in
                if succeeded {
                    continuation.resume(returning: .succeeded)
                } else if let error = error as? LAError, Self.isCancellation(error) {
                    continuation.resume(returning: .cancelled)
                } else {
                    continuation.resume(
                        returning: .failed(error?.localizedDescription ?? "Authentication didn't succeed.")
                    )
                }
            }
        }
    }

    nonisolated private static func isCancellation(_ error: LAError) -> Bool {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback: true
        default: false
        }
    }
}

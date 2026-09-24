#if os(iOS)
import UIKit

/// A tap that runs alongside whatever gestures the embedded content already
/// owns, and toggles the preview's bars the way a tap does in Photos.
///
/// `QLPreviewController`, `PDFView`, `AVPlayerViewController` and `WKWebView`
/// each handle touches with their own recognizers, and by default a
/// recognizer on a subview wins over one on an ancestor — which is why a
/// plain SwiftUI `.onTapGesture` layered outside them never sees the touch.
/// Installing directly on the content's own view, with a delegate that always
/// allows simultaneous recognition, is what lets the tap through. A tap on
/// one of the content's own controls — a play button, a scrubber — is left
/// to that control.
@MainActor
final class PreviewGestureInstaller: NSObject, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?

    func install(on view: UIView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, current !== gestureRecognizer.view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    @objc private func handleTap() {
        onTap?()
    }
}
#endif

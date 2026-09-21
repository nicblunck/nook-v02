#if os(iOS)
import UIKit

/// A tap and a pan that always run alongside whatever gestures the embedded
/// content already owns.
///
/// `QLPreviewView`, `PDFView` and `WKWebView` each scroll and zoom with their
/// own recognizers, and by default a recognizer on a subview wins over one on
/// an ancestor — which is why a plain SwiftUI `.gesture()` layered outside
/// them never sees the touch. Installing directly on the content's own view,
/// with a delegate that always allows simultaneous recognition, is what lets
/// a swipe step to the next object and a tap toggle the chrome even while the
/// content underneath is mid-scroll or mid-zoom.
@MainActor
final class PreviewGestureInstaller: NSObject, UIGestureRecognizerDelegate {
    var onStep: ((Int) -> Void)?
    var onTap: (() -> Void)?

    func install(on view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let translation = recognizer.translation(in: recognizer.view)
        guard abs(translation.x) > abs(translation.y) * 1.5, abs(translation.x) > 60 else { return }
        onStep?(translation.x < 0 ? 1 : -1)
    }

    @objc private func handleTap() {
        onTap?()
    }
}
#endif

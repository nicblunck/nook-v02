import SwiftUI

/// A photo the way Photos shows one: fitted to the screen, pinch to zoom,
/// double-tap to zoom in on a spot and back out.
///
/// All of that is the platform scroll view's own zooming — `UIScrollView`
/// on iOS, `NSScrollView` magnification on the Mac — so the feel, the
/// rubber-banding and the trackpad gestures are exactly the system's. Quick
/// Look's embedded viewer cannot be zoomed on the Mac at all, which is why
/// images do not go through it.
#if canImport(UIKit)
import UIKit

struct ZoomableImageView: UIViewRepresentable {
    let url: URL
    var onTap: (() -> Void)? = nil
    /// Swiping up on a photo shown whole brings up its info, as in Photos.
    var onSwipeUp: (() -> Void)? = nil

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.onTap = onTap
        view.onSwipeUp = onSwipeUp
        view.load(url)
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.onTap = onTap
        view.onSwipeUp = onSwipeUp
        view.load(url)
    }

    final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
        var onTap: (() -> Void)?
        var onSwipeUp: (() -> Void)?
        private let imageView = UIImageView()
        private let swipeUp = UISwipeGestureRecognizer()
        private var loadedURL: URL?
        private var fittedBounds: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            // Full-bleed: the photo runs under the bars, which float over it,
            // rather than stopping at them and leaving a band behind.
            contentInsetAdjustmentBehavior = .never
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            decelerationRate = .fast
            bouncesZoom = true
            addSubview(imageView)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
            singleTap.require(toFail: doubleTap)
            addGestureRecognizer(singleTap)

            swipeUp.direction = .up
            swipeUp.addTarget(self, action: #selector(handleSwipeUp))
            addGestureRecognizer(swipeUp)
        }

        /// A zoomed-in photo pans with an upward drag instead.
        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer === swipeUp { return zoomScale <= minimumZoomScale + 0.001 }
            return super.gestureRecognizerShouldBegin(recognizer)
        }

        @objc private func handleSwipeUp() { onSwipeUp?() }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func load(_ url: URL) {
            guard url != loadedURL else { return }
            loadedURL = url
            imageView.image = nil
            Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) {
                    await UIImage(contentsOfFile: url.path)?.byPreparingForDisplay()
                }.value
                guard let self, self.loadedURL == url else { return }
                self.imageView.image = image
                self.fittedBounds = .zero
                self.setNeedsLayout()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Fits afresh whenever the space changes — a rotation, the first
            // layout — but leaves a zoom the person made alone otherwise.
            if bounds.size != fittedBounds { fit() }
            centerImage()
        }

        private func fit() {
            guard let size = imageView.image?.size, size.width > 0, size.height > 0,
                  bounds.width > 0, bounds.height > 0
            else { return }
            fittedBounds = bounds.size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            let fitScale = min(bounds.width / size.width, bounds.height / size.height)
            minimumZoomScale = fitScale
            // Close enough to see every pixel, and never less than 3× fitted.
            maximumZoomScale = max(fitScale * 3, 1)
            zoomScale = fitScale
        }

        /// A photo narrower or shorter than the screen sits in the middle of it.
        private func centerImage() {
            let horizontal = max(0, (bounds.width - contentSize.width) / 2)
            let vertical = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: vertical, left: horizontal,
                                        bottom: vertical, right: horizontal)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

        @objc private func handleSingleTap() { onTap?() }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            if zoomScale > minimumZoomScale {
                setZoomScale(minimumZoomScale, animated: true)
                return
            }
            let point = recognizer.location(in: imageView)
            let scale = min(maximumZoomScale, minimumZoomScale * 2.5)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}

#elseif canImport(AppKit)
import AppKit

struct ZoomableImageView: NSViewRepresentable {
    let url: URL
    /// Double-clicking the photo goes back to the gallery, as in Photos.
    var onClose: (() -> Void)? = nil
    /// Handed the zoom keys while this is the page on screen.
    var keys: PreviewPageKeys? = nil

    func makeNSView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.onClose = onClose
        view.load(url)
        return view
    }

    func updateNSView(_ view: ZoomingScrollView, context: Context) {
        view.onClose = onClose
        view.load(url)
        keys?.zoomToActualSize = { [weak view] in view?.toggleActualSize() }
        keys?.zoom = { [weak view] in view?.zoom(by: $0) }
    }

    final class ZoomingScrollView: NSScrollView {
        var onClose: (() -> Void)?
        /// Where Z came from, so pressing it again goes back there.
        private var magnificationBeforeActualSize: CGFloat?
        private let imageView = NSImageView()
        private var loadedURL: URL?
        private var fittedSize: CGSize = .zero
        /// The zoom at which the whole photo just fits.
        private var fitMagnification: CGFloat = 1

        override init(frame: NSRect) {
            super.init(frame: frame)
            contentView = CenteringClipView()
            drawsBackground = false
            hasHorizontalScroller = true
            hasVerticalScroller = true
            autohidesScrollers = true
            scrollerStyle = .overlay
            allowsMagnification = true
            imageView.imageScaling = .scaleAxesIndependently
            imageView.animates = true
            documentView = imageView
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func load(_ url: URL) {
            guard url != loadedURL else { return }
            loadedURL = url
            imageView.image = nil
            Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) {
                    NSImage(contentsOf: url)
                }.value
                guard let self, self.loadedURL == url else { return }
                self.imageView.image = image
                self.fittedSize = .zero
                self.needsLayout = true
            }
        }

        override func layout() {
            super.layout()
            if bounds.size != fittedSize { fit() }
        }

        private func fit() {
            guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
                  bounds.width > 0, bounds.height > 0
            else { return }
            let wasFitted = fittedSize == .zero || isFitted
            fittedSize = bounds.size
            imageView.frame = CGRect(origin: .zero, size: image.size)
            let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            fitMagnification = fitScale
            // A photo smaller than the view can still be seen at 100%.
            minMagnification = min(fitScale, 1)
            maxMagnification = max(fitScale * 4, 2)
            if wasFitted { magnification = fitScale }
        }

        private var isFitted: Bool {
            imageView.image == nil || abs(magnification - fitMagnification) < 0.001
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onClose?()
            } else {
                super.mouseDown(with: event)
            }
        }

        /// Z: between the current zoom and 100%, as in Photos.
        func toggleActualSize() {
            let center = visibleCenter
            if abs(magnification - 1) > 0.001 {
                magnificationBeforeActualSize = magnification
                setZoom(1, centeredAt: center)
            } else {
                setZoom(magnificationBeforeActualSize ?? fitMagnification, centeredAt: center)
            }
        }

        /// Command-Plus and Command-Minus, a step at a time about the middle
        /// of what is showing.
        func zoom(by steps: Int) {
            let target = magnification * pow(1.5, CGFloat(steps))
            // Never smaller than fitted, as in Photos.
            setZoom(min(max(target, fitMagnification), maxMagnification), centeredAt: visibleCenter)
        }

        /// Animated on screen, as Photos zooms; straight there otherwise.
        private func setZoom(_ target: CGFloat, centeredAt point: CGPoint) {
            if window?.isVisible == true {
                animator().setMagnification(target, centeredAt: point)
            } else {
                setMagnification(target, centeredAt: point)
            }
        }

        private var visibleCenter: CGPoint {
            let visible = contentView.documentVisibleRect
            return CGPoint(x: visible.midX, y: visible.midY)
        }

        /// Double-tapping with two fingers zooms into that spot and back.
        override func smartMagnify(with event: NSEvent) {
            if !isFitted {
                setZoom(fitMagnification, centeredAt: visibleCenter)
            } else {
                let point = imageView.convert(event.locationInWindow, from: nil)
                setZoom(min(maxMagnification, fitMagnification * 2.5), centeredAt: point)
            }
        }

        /// A photo shown whole — or not loaded at all — has nothing to scroll,
        /// so a swipe across it belongs to the pages around it.
        override func scrollWheel(with event: NSEvent) {
            if isFitted {
                nextResponder?.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }

    /// Keeps a photo smaller than the view in the middle of it rather than
    /// pinned to a corner.
    final class CenteringClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposedBounds)
            guard let document = documentView else { return rect }
            let frame = document.frame
            if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
            if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
            return rect
        }
    }
}
#endif

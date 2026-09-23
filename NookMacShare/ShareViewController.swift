import AppKit
import SwiftUI

final class ShareViewController: NSViewController {
    /// The sheet's size. MacShareView fills it and scrolls whatever doesn't fit.
    private static let sheetSize = NSSize(width: 480, height: 620)

    private var hostingController: NSHostingController<MacShareView>?

    /// Rounder than the system's own sheet corners, so the sheet reads as a
    /// card of the same family as the rounded blocks inside it.
    private static let cornerRadius: CGFloat = 28

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.sheetSize))
        // The system may give the sheet less height than asked for; the view
        // has to follow the window it actually gets, not keep its own size.
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.cornerRadius = Self.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }

    /// The system hosts the sheet in a visual effect view whose material and
    /// shadow follow its own, tighter corners. Masking it to the same radius
    /// keeps its corners from showing past ours.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard let effectView = view.superview as? NSVisualEffectView else { return }
        effectView.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        view.window?.invalidateShadow()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        // The title the host app put on the extension item is what the share
        // sheet itself showed for this item, so it is carried alongside each
        // attachment rather than dropped here.
        let attachments = items.flatMap { item in
            (item.attachments ?? []).map {
                SharedAttachment(provider: $0, sharedTitle: item.attributedTitle?.string)
            }
        }

        let rootView = MacShareView(
            attachments: attachments,
            onFinish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: CocoaError(.userCancelled)
                )
            }
        )

        let host = NSHostingController(rootView: rootView)
        hostingController = host
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        preferredContentSize = Self.sheetSize
    }
}

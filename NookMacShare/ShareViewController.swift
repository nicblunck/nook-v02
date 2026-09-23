import AppKit
import OSLog
import SwiftUI

final class ShareViewController: NSViewController {
    /// The sheet's size. MacShareView fills it and scrolls whatever doesn't fit.
    private static let sheetSize = NSSize(width: 480, height: 620)

    private var hostingController: NSHostingController<MacShareView>?

    private static let log = Logger(subsystem: "com.nicolasblunck.nook.app.macshare", category: "layout")

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.sheetSize))
        // The system may give the sheet less height than asked for; the view
        // has to follow the window it actually gets, not keep its own size.
        view.autoresizingMask = [.width, .height]
    }

    // TEMPORARY: logs the sheet's real geometry so the clipped header can be
    // diagnosed from the unified log. Remove once the clipping is fixed.
    override func viewDidLayout() {
        super.viewDidLayout()
        let window = view.window
        let superview = view.superview
        let parts: [String] = [
            "view=\(NSStringFromRect(view.frame))",
            "superview=\(superview.map { String(describing: type(of: $0)) } ?? "nil")",
            "superFrame=\(NSStringFromRect(superview?.frame ?? .zero))",
            "superFlipped=\(superview?.isFlipped ?? false)",
            "host=\(NSStringFromRect(hostingController?.view.frame ?? .zero))",
            "safeArea=\(view.safeAreaInsets)",
            "hostSafeArea=\(String(describing: hostingController?.view.safeAreaInsets))",
            "window=\(NSStringFromRect(window?.frame ?? .zero))",
            "contentView=\(NSStringFromRect(window?.contentView?.frame ?? .zero))",
            "contentLayout=\(NSStringFromRect(window?.contentLayoutRect ?? .zero))",
            "isContentView=\(window?.contentView === view)",
            "styleMask=\(window?.styleMask.rawValue ?? 0)"
        ]
        let line = parts.joined(separator: " ")
        Self.log.notice("share-geometry \(line, privacy: .public)")
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

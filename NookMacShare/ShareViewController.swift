import AppKit
import SwiftUI

final class ShareViewController: NSViewController {
    /// The sheet's size. MacShareView fills it and scrolls whatever doesn't fit.
    private static let sheetSize = NSSize(width: 480, height: 620)

    private var hostingController: NSHostingController<MacShareView>?

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.sheetSize))
        // The system may give the sheet less height than asked for; the view
        // has to follow the window it actually gets, not keep its own size.
        view.autoresizingMask = [.width, .height]
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

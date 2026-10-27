import AppKit
import SwiftUI

/// The Quick Save entry in the Mac share menu.
///
/// It writes into the same library as Save to Nook, through the shared app
/// group container, but asks nothing first: see QuickSaveView.
final class QuickSaveViewController: NSViewController {
    /// Only big enough for the status: there is nothing to fill in.
    private static let sheetSize = NSSize(width: 320, height: 220)

    private var hostingController: NSHostingController<QuickSaveView>?

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.sheetSize))
        view.autoresizingMask = [.width, .height]
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let attachments = items.flatMap { item in
            (item.attachments ?? []).map {
                SharedAttachment(provider: $0, sharedTitle: item.attributedTitle?.string)
            }
        }

        let rootView = QuickSaveView(
            attachments: attachments,
            onFinish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
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

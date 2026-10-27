import UIKit
import SwiftUI

/// The Quick Save entry in the share sheet.
///
/// It writes into the same library as Save to Nook, through the shared app
/// group container, but asks nothing first: see QuickSaveView.
final class QuickSaveViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let attachments = items.flatMap { item in
            (item.attachments ?? []).map {
                SharedAttachment(provider: $0, sharedTitle: item.attributedTitle?.string)
            }
        }

        let view = QuickSaveView(
            attachments: attachments,
            onFinish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )

        let host = UIHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

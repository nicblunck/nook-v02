import UIKit
import SwiftUI
import UniformTypeIdentifiers
import NookLibrary

/// The share sheet entry point.
///
/// It writes into the same managed library the app reads, through the shared
/// app group container — so something saved from Safari is in the library
/// before the app is ever opened.
final class ShareViewController: UIViewController {

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

        let view = ShareView(
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

        let host = UIHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

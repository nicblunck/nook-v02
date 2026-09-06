import SwiftUI
import QuickLook

#if canImport(AppKit)
import AppKit
import QuickLookUI

/// Native preview for file types the app has no reader of its own for.
///
/// Quick Look already knows how to render most documents, so anything outside
/// the handful of types Nook presents itself falls through to the system
/// rather than to a placeholder.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    /// AppKit has no equivalent of `QLPreviewController.canPreview`; the
    /// preview view falls back to a document icon on its own for anything it
    /// cannot render.
    static func canPreview(_ url: URL) -> Bool { true }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        guard (nsView.previewItem as? URL) != url else { return }
        nsView.previewItem = url as NSURL
    }
}

#elseif canImport(UIKit)
import UIKit

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    static func canPreview(_ url: URL) -> Bool {
        QLPreviewController.canPreview(url as NSURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
#endif

import SwiftUI
import QuickLook

#if canImport(AppKit)
import AppKit
import QuickLookUI

/// Shared native viewer for images, documents, video, and audio.
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

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
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
    var onStep: ((Int) -> Void)? = nil
    var onTap: (() -> Void)? = nil

    static func canPreview(_ url: URL) -> Bool {
        QLPreviewController.canPreview(url as NSURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        context.coordinator.installer.install(on: controller.view)
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.installer.onStep = onStep
        context.coordinator.installer.onTap = onTap
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        let installer = PreviewGestureInstaller()

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
#endif

import SwiftUI
import PDFKit

/// All of a PDF's pages, laid out for continuous vertical scrolling —
/// PDFKit's own default reading mode, and the one genuinely native "default
/// PDF viewer" on both platforms. Unlike `QLPreviewController`, it carries no
/// chrome of its own — no page-thumbnail strip, no share bar — so the
/// content stays clean and the app's own toolbar is the only thing that ever
/// shows or hides.
#if canImport(UIKit)
import UIKit

struct PDFKitPreview: UIViewRepresentable {
    let url: URL
    var onStep: ((Int) -> Void)? = nil
    var onTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view)
        view.document = PDFDocument(url: url)
        context.coordinator.installer.install(on: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.installer.onStep = onStep
        context.coordinator.installer.onTap = onTap
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.document = PDFDocument(url: url)
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    private func configure(_ view: PDFView) {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
    }

    @MainActor
    final class Coordinator {
        var url: URL
        let installer = PreviewGestureInstaller()
        init(url: URL) { self.url = url }
    }
}

#elseif canImport(AppKit)
import AppKit

struct PDFKitPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view)
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.document = PDFDocument(url: url)
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    private func configure(_ view: PDFView) {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
    }

    final class Coordinator {
        var url: URL
        init(url: URL) { self.url = url }
    }
}
#endif

import SwiftUI
import PDFKit

#if canImport(AppKit)
import AppKit
typealias ViewRepresentable = NSViewRepresentable
#elseif canImport(UIKit)
import UIKit
typealias ViewRepresentable = UIViewRepresentable
#endif

/// Native PDF presentation. The library previews documents; it does not edit
/// them, so the view is read-only by construction.
struct DocumentPreview: ViewRepresentable {
    let url: URL

    private func makeDocumentView() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    private func update(_ view: PDFView) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
    }

    #if canImport(AppKit)
    func makeNSView(context: Context) -> PDFView { makeDocumentView() }
    func updateNSView(_ nsView: PDFView, context: Context) { update(nsView) }
    #else
    func makeUIView(context: Context) -> PDFView { makeDocumentView() }
    func updateUIView(_ uiView: PDFView, context: Context) { update(uiView) }
    #endif
}

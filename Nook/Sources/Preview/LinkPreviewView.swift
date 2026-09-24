import SwiftUI
import WebKit
import NookLibrary

/// A link has no stored file to hand Quick Look — the page itself is the
/// content. What importing it captured (thumbnail, title, domain) sits above
/// the live page, with a way to leave for the real browser.
struct LinkPreviewView: View {
    let model: LibraryModel
    let object: ObjectSnapshot
    #if os(iOS)
    var onTap: (() -> Void)? = nil
    #endif
    /// The bars' height, which the page's own header keeps clear of while
    /// the preview itself runs under them.
    var chromeInsets = EdgeInsets()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let url = object.sourceURL {
                #if os(iOS)
                WebPageView(url: url, onTap: onTap)
                #else
                WebPageView(url: url)
                #endif
            } else {
                Spacer()
            }
        }
        .padding(.top, chromeInsets.top)
        .padding(.bottom, chromeInsets.bottom)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ThumbnailView(object: object, maximumSize: 160)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(object.title)
                    .font(.headline)
                    .lineLimit(1)
                if let domain = object.sourceDomain {
                    Text(domain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let url = object.sourceURL {
                Button {
                    OpenExternally.open(url)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("Open in Browser")
            }
        }
        .padding(12)
        .background(.background.secondary)
    }
}

#if canImport(UIKit)
import UIKit

private struct WebPageView: UIViewRepresentable {
    let url: URL
    var onTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        context.coordinator.installer.install(on: view.scrollView)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.installer.onTap = onTap
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        view.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var loadedURL: URL?
        let installer = PreviewGestureInstaller()
    }
}

#elseif canImport(AppKit)
import AppKit

private struct WebPageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        view.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedURL: URL?
    }
}
#endif

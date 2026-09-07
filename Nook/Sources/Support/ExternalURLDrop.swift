import SwiftUI
import UniformTypeIdentifiers

/// A file/link drop from outside Nook.
///
/// This deliberately registers only URL UTIs instead of using a generic
/// URL Transferable destination. Nook's in-app object transfer also offers
/// a file representation for Finder, and a generic URL destination can then
/// incorrectly mark the whole canvas as a file drop while an object is merely
/// being moved inside Nook.
struct ExternalURLDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    let action: ([URL]) -> Void

    func body(content: Content) -> some View {
        content.onDrop(
            of: [UTType.fileURL.identifier, UTType.url.identifier],
            isTargeted: $isTargeted
        ) { providers in
            Task { @MainActor in
                let urls = await ExternalURLDropLoader.urls(from: providers)
                guard !urls.isEmpty else { return }
                action(urls)
            }
            return true
        }
    }
}

extension View {
    func externalURLDrop(isTargeted: Binding<Bool>, perform action: @escaping ([URL]) -> Void) -> some View {
        modifier(ExternalURLDropModifier(isTargeted: isTargeted, action: action))
    }
}

@MainActor
private enum ExternalURLDropLoader {
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await url(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL)?.absoluteURL)
            }
        }
    }
}

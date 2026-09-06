import SwiftUI

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    /// Builds a SwiftUI image from raw bytes, without either platform's image
    /// type leaking into the views that use it.
    init?(platformData data: Data) {
        guard let image = PlatformImage(data: data) else { return nil }
        #if canImport(AppKit)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

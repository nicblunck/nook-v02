import SwiftUI

#if os(iOS)
import UIKit

/// One page of the iOS navigation stack.
///
/// There is one canvas, and it can only show one place: wherever the model
/// is. So only the page that place belongs to draws it live. Every page the
/// stack has covered is drawn as a still of how it was left, which is what
/// the edge swipe uncovers while it is being dragged, and what stays up once
/// the page is back on top until its place has loaded again.
struct LibraryPageView: View {
    @Bindable var model: LibraryModel
    let page: LibraryPage
    /// The iPad detail column's first page. Picking a place in the sidebar
    /// changes it in place, and it keeps showing the last place until the
    /// next has loaded, the way the canvas always has.
    var isRoot = false

    @Environment(PageStills.self) private var stills
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if page.previewedObjectID != nil {
            BrowseView(model: model, stackPage: page)
        } else if model.livePageID == page.id {
            live
        } else {
            covered
        }
    }

    private var live: some View {
        BrowseView(model: model, stackPage: page, showsPlaceOnlyOnceLoaded: !isRoot)
            .background { PageProbe(id: page.id, stills: stills) }
            .overlay {
                if isAwaitingPlace, let still = stills[page.id] {
                    PageStill(view: still)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? NookMotion.reduced : NookMotion.presentation,
                       value: isAwaitingPlace)
    }

    private var covered: some View {
        Group {
            if let still = stills[page.id] {
                PageStill(view: still)
            } else {
                Color(uiColor: .systemBackground)
            }
        }
        .ignoresSafeArea()
        .navigationTitle(model.title(for: page.destination))
        .navigationBarTitleDisplayMode(.inline)
        // The same bars as the live page, so the edge swipe uncovers the
        // page's own chrome rather than an empty bar.
        .toolbar {
            GalleryToolbar(model: model, showsHistoryControls: false, isPreviewing: false)
            if horizontalSizeClass == .compact {
                CompactAddContentToolbar(model: model)
            }
        }
    }

    private var isAwaitingPlace: Bool {
        model.contentsDestination != page.destination
    }
}

extension View {
    /// Stills for the pages a stack covers: taken of each page as another is
    /// pushed over it, and let go once the page has left the stack.
    func libraryPageStills(_ stills: PageStills, model: LibraryModel) -> some View {
        environment(stills)
            // Runs before the push is drawn, so what is on screen is still
            // the page being covered.
            .onChange(of: model.pages.last?.id) { covered, _ in
                if let covered { stills.capture(covered) }
            }
            .onChange(of: model.pages) {
                stills.keep(Set(model.pages.map(\.id)))
            }
    }
}

/// Stills of pages, as the system draws them.
@MainActor
@Observable
final class PageStills {
    private var views: [LibraryPage.ID: UIView] = [:]
    @ObservationIgnored private var probes: [LibraryPage.ID: WeakView] = [:]

    subscript(id: LibraryPage.ID) -> UIView? { views[id] }

    fileprivate func register(_ probe: UIView, for id: LibraryPage.ID) {
        probes[id] = WeakView(view: probe)
    }

    func capture(_ id: LibraryPage.ID) {
        guard let page = probes[id]?.view?.pageView, page.window != nil,
              let still = page.snapshotView(afterScreenUpdates: false)
        else { return }
        views[id] = still
    }

    func keep(_ ids: Set<LibraryPage.ID>) {
        views = views.filter { ids.contains($0.key) }
        probes = probes.filter { ids.contains($0.key) && $0.value.view != nil }
    }

    private struct WeakView {
        weak var view: UIView?
    }
}

/// Marks where a page is, so its still can be taken of the whole page —
/// everything the navigation controller shows beneath its bars — rather
/// than just the canvas.
private struct PageProbe: UIViewRepresentable {
    let id: LibraryPage.ID
    let stills: PageStills

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        stills.register(view, for: id)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        stills.register(view, for: id)
    }
}

private struct PageStill: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}

private extension UIView {
    /// The view of the page this view sits on: the controller the navigation
    /// controller pushed.
    var pageView: UIView? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController,
               controller.parent is UINavigationController {
                return controller.view
            }
            responder = current.next
        }
        return nil
    }
}
#endif

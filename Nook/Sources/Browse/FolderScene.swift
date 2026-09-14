import SwiftUI

/// The folder, drawn: a back panel, the few things inside standing up behind
/// it, and the front panel over the top. Every folder the app draws is this
/// view — the gallery's and the welcome screen's — so its proportions, how it
/// opens, and the paper its contents are printed on live here and nowhere else.
///
/// Callers supply only what goes *on* the sheets, and how open the folder is:
/// `openness` is 0 shut and 1 open, and may be pushed a little past 1 to
/// exaggerate a folder that is already open.
struct FolderScene<Content: View, Stamp: View>: View {
    var width: CGFloat
    var tint: Color
    var openness: CGFloat
    var sheetCount: Int
    /// Drawn back to front, so the last one ends up in front and centred.
    @ViewBuilder var sheet: (Int, CGSize) -> Content
    /// The folder's own symbol or emoji, sized against the folder height it
    /// is handed.
    @ViewBuilder var stamp: (CGFloat) -> Stamp

    init(
        width: CGFloat,
        tint: Color,
        openness: CGFloat,
        sheetCount: Int,
        @ViewBuilder sheet: @escaping (Int, CGSize) -> Content,
        @ViewBuilder stamp: @escaping (CGFloat) -> Stamp
    ) {
        self.width = width
        self.tint = tint
        self.openness = openness
        self.sheetCount = sheetCount
        self.sheet = sheet
        self.stamp = stamp
    }

    /// Traced from a supplied reference pair (`Front.svg`/`Back.svg`, 236×155
    /// and 236×171): the back silhouette is taller than the front panel by
    /// exactly the tab's rise, so this ratio and `frontHeight` below both
    /// come from the same two numbers and stay in lockstep.
    private static var aspect: CGFloat { 236.0 / 171.0 }
    private static var frontHeight: CGFloat { 155.0 / 171.0 }

    static func height(for width: CGFloat) -> CGFloat { width / aspect }

    private var height: CGFloat { Self.height(for: width) }

    private func lerp(_ shut: CGFloat, _ open: CGFloat) -> CGFloat {
        shut + (open - shut) * openness
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            FolderBackShape()
                .fill(tint.gradient.opacity(0.55))
                .frame(width: width, height: height)
                // A few points above the front panel's own bottom edge, so
                // the tab stands up a little taller than a literal trace of
                // the reference would put it — its hidden lower edge just
                // ends up a hair short of the front panel's, unseen either way.
                .offset(y: -height * 0.035)

            ForEach(0..<sheetCount, id: \.self) { index in
                sheetView(at: index)
            }

            frontPanel
        }
        .frame(width: width, height: height, alignment: .bottom)
        // The bottom edge is pinned, so the sheets rising higher as the
        // folder opens only ever grows the drawing upward — left alone, an
        // open folder reads as sitting higher than a shut one. Sinking the
        // whole scene by half of that rise keeps the composition's centre
        // where it was when shut, instead of climbing toward the top of the
        // icon's box.
        .offset(y: (lerp(0.20, 0.62) - 0.20) / 2 * height)
    }

    private var frontPanel: some View {
        FolderFrontShape()
            .fill(tint.gradient)
            .overlay(alignment: .center) {
                stamp(height).offset(y: height * 0.04)
            }
            .overlay {
                FolderFrontShape()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
            }
            .frame(width: width, height: height * Self.frontHeight)
            .shadow(
                color: .black.opacity(lerp(0.12, 0.22)),
                radius: lerp(2, 5.5),
                y: 1.75
            )
            // Negative tips the top edge towards the viewer, so the folder
            // opens rather than folding shut.
            .rotation3DEffect(
                .degrees(lerp(0, -17)),
                axis: (x: 1, y: 0, z: 0),
                anchor: .bottom,
                perspective: 0.6
            )
    }

    // MARK: - Contents

    private enum Slot { case left, right, centre }

    private func slot(at index: Int) -> Slot {
        switch (sheetCount, index) {
        case (3, 0): return .left
        case (3, 1): return .right
        case (2, 0): return .left
        default: return .centre
        }
    }

    /// The contents rise nearly straight out of the top: the outer two step
    /// barely aside and tip barely at all, so three things stay readable as
    /// three without the stack splaying open.
    private func sheetView(at index: Int) -> some View {
        let slot = slot(at: index)
        let size = CGSize(width: width * 0.60, height: height * 0.66)
        let spread: CGFloat = {
            switch slot {
            case .left: return -lerp(0.09, 0.11)
            case .right: return lerp(0.09, 0.11)
            case .centre: return 0
            }
        }()
        let tilt: CGFloat = {
            switch slot {
            case .left: return -lerp(4, 5)
            case .right: return lerp(4, 5)
            case .centre: return 0
            }
        }()
        let rise = lerp(0.20, 0.62) + (slot == .centre ? 0.05 * openness : 0)
        let corner = size.height * 0.07

        return sheet(index, size)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .rotationEffect(.degrees(tilt), anchor: .bottom)
            .offset(x: width * spread, y: -height * rise)
    }
}

extension FolderScene where Stamp == EmptyView {
    init(
        width: CGFloat,
        tint: Color,
        openness: CGFloat,
        sheetCount: Int,
        @ViewBuilder sheet: @escaping (Int, CGSize) -> Content
    ) {
        self.init(
            width: width,
            tint: tint,
            openness: openness,
            sheetCount: sheetCount,
            sheet: sheet,
            stamp: { _ in EmptyView() }
        )
    }
}

// MARK: - Shapes


/// The back of the folder: a tab at the left standing above the panel,
/// traced point-for-point from a 236×171 reference (`Back.svg`) rather than
/// approximated. Below the tab's rise it is `FolderFrontShape`'s own curve,
/// shifted down — the two files share every corner but the tab.
nonisolated struct FolderBackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 236
        let sy = rect.height / 171
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        path.move(to: pt(0, 25.6))
        path.addCurve(to: pt(1.7439, 8.73615), control1: pt(0, 16.6392), control2: pt(0, 12.1587))
        path.addCurve(to: pt(8.73615, 1.7439), control1: pt(3.27787, 5.72556), control2: pt(5.72556, 3.27787))
        path.addCurve(to: pt(25.6, 0), control1: pt(12.1587, 0), control2: pt(16.6392, 0))
        path.addLine(to: pt(63.3961, 0))
        path.addCurve(to: pt(71.1077, 0.442081), control1: pt(67.3096, 0), control2: pt(69.2663, 0))
        path.addCurve(to: pt(75.7326, 2.35776), control1: pt(72.7403, 0.834029), control2: pt(74.301, 1.4805))
        path.addCurve(to: pt(81.4981, 7.49807), control1: pt(77.3472, 3.34723), control2: pt(78.7308, 4.73084))
        path.addLine(to: pt(82.5019, 8.50194))
        path.addCurve(to: pt(88.2674, 13.6422), control1: pt(85.2692, 11.2692), control2: pt(86.6528, 12.6528))
        path.addCurve(to: pt(92.8923, 15.5579), control1: pt(89.699, 14.5195), control2: pt(91.2597, 15.166))
        path.addCurve(to: pt(100.604, 16), control1: pt(94.7337, 16), control2: pt(96.6904, 16))
        path.addLine(to: pt(210.4, 16))
        path.addCurve(to: pt(227.264, 17.7439), control1: pt(219.361, 16), control2: pt(223.841, 16))
        path.addCurve(to: pt(234.256, 24.7362), control1: pt(230.274, 19.2779), control2: pt(232.722, 21.7256))
        path.addCurve(to: pt(236, 41.6), control1: pt(236, 28.1587), control2: pt(236, 32.6392))
        path.addLine(to: pt(236, 145.4))
        path.addCurve(to: pt(234.256, 162.264), control1: pt(236, 154.361), control2: pt(236, 158.841))
        path.addCurve(to: pt(227.264, 169.256), control1: pt(232.722, 165.274), control2: pt(230.274, 167.722))
        path.addCurve(to: pt(210.4, 171), control1: pt(223.841, 171), control2: pt(219.361, 171))
        path.addLine(to: pt(25.6, 171))
        path.addCurve(to: pt(8.73615, 169.256), control1: pt(16.6392, 171), control2: pt(12.1587, 171))
        path.addCurve(to: pt(1.7439, 162.264), control1: pt(5.72556, 167.722), control2: pt(3.27787, 165.274))
        path.addCurve(to: pt(0, 145.4), control1: pt(0, 158.841), control2: pt(0, 154.361))
        path.addLine(to: pt(0, 25.6))
        path.closeSubpath()
        return path
    }
}

/// The front panel: the same 236×155 rounded rect as `FolderBackShape`'s
/// body, traced from `Front.svg` rather than SwiftUI's own continuous corner
/// — close, but not close enough to sit on top of the back panel's curve
/// without a visible seam at the join.
nonisolated struct FolderFrontShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let sx = r.width / 236
        let sy = r.height / 155
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + x * sx, y: r.minY + y * sy)
        }

        var path = Path()
        path.move(to: pt(0, 25.6))
        path.addCurve(to: pt(1.7439, 8.73615), control1: pt(0, 16.6392), control2: pt(0, 12.1587))
        path.addCurve(to: pt(8.73615, 1.7439), control1: pt(3.27787, 5.72556), control2: pt(5.72556, 3.27787))
        path.addCurve(to: pt(25.6, 0), control1: pt(12.1587, 0), control2: pt(16.6392, 0))
        path.addLine(to: pt(210.4, 0))
        path.addCurve(to: pt(227.264, 1.7439), control1: pt(219.361, 0), control2: pt(223.841, 0))
        path.addCurve(to: pt(234.256, 8.73615), control1: pt(230.274, 3.27787), control2: pt(232.722, 5.72556))
        path.addCurve(to: pt(236, 25.6), control1: pt(236, 12.1587), control2: pt(236, 16.6392))
        path.addLine(to: pt(236, 129.4))
        path.addCurve(to: pt(234.256, 146.264), control1: pt(236, 138.361), control2: pt(236, 142.841))
        path.addCurve(to: pt(227.264, 153.256), control1: pt(232.722, 149.274), control2: pt(230.274, 151.722))
        path.addCurve(to: pt(210.4, 155), control1: pt(223.841, 155), control2: pt(219.361, 155))
        path.addLine(to: pt(25.6, 155))
        path.addCurve(to: pt(8.73615, 153.256), control1: pt(16.6392, 155), control2: pt(12.1587, 155))
        path.addCurve(to: pt(1.7439, 146.264), control1: pt(5.72556, 151.722), control2: pt(3.27787, 149.274))
        path.addCurve(to: pt(0, 129.4), control1: pt(0, 142.841), control2: pt(0, 138.361))
        path.addLine(to: pt(0, 25.6))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.inset += amount
        return copy
    }
}


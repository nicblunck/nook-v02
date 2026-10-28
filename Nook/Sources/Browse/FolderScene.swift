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

/// The folder's corner radius, in the 236-wide units of the reference
/// drawings. Both panels round their corners with SwiftUI's continuous
/// curve at this radius, so the front sits exactly over the back's body.
private let folderCornerRadius: CGFloat = 36

/// The back of the folder: a tab at the left standing above the panel. The
/// body is the front panel's own continuous rounded rect, shifted down by
/// the tab's rise; the tab joins it, with its outer corner rounded to match
/// and an S-curve slope down to the body's top edge.
nonisolated struct FolderBackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 236
        let sy = rect.height / 171
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        let radius = folderCornerRadius * min(sx, sy)
        let rise: CGFloat = 16

        let body = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(x: rect.minX, y: rect.minY + rise * sy,
                             width: rect.width, height: rect.height - rise * sy))

        // Where the tab's flat top ends and where its slope lands on the
        // body. The slope is one S-curve, level at both ends, so it leaves
        // the tab and meets the body without a visible join at either.
        let slopeStart: CGFloat = 58
        let slopeEnd: CGFloat = 108
        let ease = (slopeEnd - slopeStart) * 0.5

        // Runs down past the body's top edge, so it fills the body's
        // rounded top-left corner and the two read as one outline.
        let tab = UnevenRoundedRectangle(topLeadingRadius: radius, style: .continuous)
            .path(in: CGRect(x: rect.minX, y: rect.minY,
                             width: slopeStart * sx, height: (rise + folderCornerRadius) * sy))

        var slope = Path()
        slope.move(to: pt(slopeStart - 4, 0))
        slope.addLine(to: pt(slopeStart, 0))
        slope.addCurve(to: pt(slopeEnd, rise),
                       control1: pt(slopeStart + ease, 0),
                       control2: pt(slopeEnd - ease, rise))
        slope.addLine(to: pt(slopeEnd, rise + 1))
        slope.addLine(to: pt(slopeStart - 4, rise + 1))
        slope.closeSubpath()

        return body.union(tab).union(slope)
    }
}

/// The front panel: a continuous rounded rect, the same one that forms the
/// back panel's body, so the two share every corner.
nonisolated struct FolderFrontShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let scale = min(r.width / 236, r.height / 155)
        return RoundedRectangle(cornerRadius: folderCornerRadius * scale, style: .continuous)
            .path(in: r)
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.inset += amount
        return copy
    }
}

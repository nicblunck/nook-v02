import SwiftUI

/// Nook's motion system.
///
/// Every animated change in the app names the *kind* of change it is rather
/// than a duration and a curve. That is the whole point of this type: two
/// things that are the same kind of change are timed identically wherever they
/// happen, and neither one has to remember what Reduce Motion should do.
///
/// The roles are also ordered in time. A content change runs as three windows
/// that do not overlap — what is leaving gets out of the way, then the layout
/// closes the gap, then what is new settles in — so nothing is ever drawn on
/// top of something that is still moving.
enum NookMotion {

    // MARK: Windows

    /// How long a departing element takes to get out of the way.
    static let exitWindow: TimeInterval = 0.16
    /// How long the layout takes to close or open the gap that leaves.
    static let reflowWindow: TimeInterval = 0.28
    /// How long a newly created element takes to settle once the layout has
    /// come to rest.
    static let enterWindow: TimeInterval = 0.24
    /// The cut between one location and the next. Deliberately the shortest
    /// window in the system: arriving somewhere should feel immediate, and
    /// anything slower than this reads as the app thinking rather than moving.
    static let navigationWindow: TimeInterval = 0.10

    /// How far apart consecutive arrivals land.
    private static let staggerStep: TimeInterval = 0.026
    /// Arrivals past this many are no longer staggered, so importing four
    /// hundred files still finishes settling in the same fraction of a second
    /// that importing seven does.
    private static let staggeredItemLimit = 6

    /// When a newly created item at this position should begin arriving.
    ///
    /// Measured from the start of the change, and offset past the reflow: an
    /// item that lands while its neighbours are still travelling looks like it
    /// was dropped on a moving grid. It waits for the grid to stop.
    static func arrivalDelay(for index: Int) -> TimeInterval {
        reflowWindow + staggerStep * Double(min(max(index, 0), staggeredItemLimit))
    }

    // MARK: Roles

    /// What kind of change is being animated.
    enum Role {
        /// The thing stays where it is and changes how it looks: a highlight
        /// coming up, a fill, a chevron turning over.
        case interaction
        /// Something coming into view or leaving it — a popover, a preview, a
        /// bar rising from an edge.
        case presentation
        /// One location replacing another.
        case navigation
        /// The layout rearranging: items closing a gap, a column re-resolving,
        /// a drawer opening.
        case reflow
        /// A departing element getting out of the way.
        case exit
        /// A newly created element settling into place.
        case enter

        /// The curve this kind of change moves on.
        ///
        /// Nothing here overshoots. A spring that overshoots scales a card
        /// past its own slot, and the gutter between two cards in the icon
        /// grid is 8pt — four of them a side. Overshoot is exactly how a card
        /// ends up drawn over its neighbour, so the character of an arrival
        /// comes from the stagger instead.
        var animation: Animation {
            switch self {
            case .interaction: .smooth(duration: 0.16)
            case .presentation: .smooth(duration: 0.24)
            case .navigation: .easeOut(duration: NookMotion.navigationWindow)
            case .reflow: .smooth(duration: NookMotion.reflowWindow)
            case .exit: .easeOut(duration: NookMotion.exitWindow)
            case .enter: .smooth(duration: NookMotion.enterWindow)
            }
        }

        /// What this becomes when the system has been asked to reduce motion.
        ///
        /// `nil` where the change is movement: movement is the thing being
        /// reduced, so the new arrangement is simply shown. Everywhere else a
        /// short fade stays — a fade is not movement, and something that
        /// appears with no transition at all reads as a glitch rather than as
        /// an accommodation.
        var reduced: Animation? {
            switch self {
            case .reflow: return nil
            default: return .easeOut(duration: 0.12)
            }
        }

        func resolved(reduceMotion: Bool) -> Animation? {
            guard reduceMotion else { return animation }
            return reduced
        }
    }

    /// For `withAnimation`, where there is no view to hang a modifier on.
    static func animation(_ role: Role, reduceMotion: Bool) -> Animation? {
        role.resolved(reduceMotion: reduceMotion)
    }
}

// MARK: Applying motion

private struct RoleMotion<Value: Equatable>: ViewModifier {
    let role: NookMotion.Role
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(role.resolved(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `animation(_:value:)` for one kind of change, with the right Reduce
    /// Motion behaviour for that kind already decided.
    func nookMotion<Value: Equatable>(_ role: NookMotion.Role, value: Value) -> some View {
        modifier(RoleMotion(role: role, value: value))
    }
}

extension AnyTransition {
    /// A transition that keeps its fade but drops its movement under Reduce
    /// Motion. Something appearing is still worth showing; it just should not
    /// fly in from an edge.
    static func motionAware(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }

    /// How an item leaves a gallery, a list or the sidebar.
    ///
    /// It shrinks a little and fades where it stands. Shrinking rather than
    /// growing is what keeps a departing item inside its own slot: on its way
    /// out it can never cross into a neighbour, however tight the gutter — and
    /// the list's gutter is one point.
    ///
    /// Arrival is not a transition here. `arriving(trigger:order:)` owns it, so
    /// that only genuinely new items animate in and an ordinary refresh does
    /// not replay the entire grid.
    static func nookDeparture(reduceMotion: Bool) -> AnyTransition {
        let removal = AnyTransition
            .motionAware(.scale(scale: 0.94).combined(with: .opacity), reduceMotion: reduceMotion)
            .animation(NookMotion.animation(.exit, reduceMotion: reduceMotion))
        return .asymmetric(insertion: .identity, removal: removal)
    }

    /// Replaces one view with another without the two ever being drawn on top
    /// of each other: the outgoing one is completely gone before the incoming
    /// one begins to appear.
    ///
    /// A plain cross-fade is the usual way to swap two views and it is exactly
    /// what this avoids — for the length of the fade both are on screen, one
    /// showing through the other.
    static func nookSwap(_ role: NookMotion.Role = .presentation, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else {
            return .opacity.animation(NookMotion.animation(.exit, reduceMotion: true))
        }
        let isNavigation = role == .navigation
        let cut = isNavigation ? NookMotion.navigationWindow : NookMotion.exitWindow
        let leaving: NookMotion.Role = isNavigation ? .navigation : .exit
        return .asymmetric(
            insertion: .opacity.animation(role.animation.delay(cut)),
            removal: .opacity.animation(leaving.animation)
        )
    }
}

// MARK: Arrival

/// Gives a newly-created item its arrival, and withholds it from everything
/// else.
///
/// The arrival waits out the reflow before it starts: the grid has to finish
/// making room before the new thing lands in it, or the item is dropped onto
/// neighbours that are still travelling. Scaling up from just under full size
/// means the item is never larger than the slot it is settling into, so an
/// arrival cannot overlap what is already there.
private struct Arriving: ViewModifier {
    let trigger: Int?
    let order: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible: Bool

    init(trigger: Int?, order: Int) {
        self.trigger = trigger
        self.order = order
        _isVisible = State(initialValue: trigger == nil)
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(reduceMotion || isVisible ? 1 : 0.94)
            .onAppear { revealIfNeeded() }
            .onChange(of: trigger) { previous, current in
                guard let current, current != previous else { return }
                isVisible = false
                Task { @MainActor in
                    await Task.yield()
                    reveal()
                }
            }
    }

    private func revealIfNeeded() {
        guard trigger != nil else {
            isVisible = true
            return
        }
        reveal()
    }

    private func reveal() {
        let animation: Animation?
        if reduceMotion {
            // Nothing travelled out of the way, so there is nothing to wait
            // for: under Reduce Motion the layout arrives in one frame and
            // the item can simply fade up into it.
            animation = NookMotion.animation(.enter, reduceMotion: true)
        } else {
            animation = NookMotion.Role.enter.animation
                .delay(NookMotion.arrivalDelay(for: order))
        }
        withAnimation(animation) {
            isVisible = true
        }
    }
}

extension View {
    /// Settles a view in when `trigger` names an explicit creation or import
    /// batch. Passing `nil` displays it immediately, which is what initial
    /// loading, navigation, searching and background refreshes want.
    func arriving(trigger: Int?, order: Int = 0) -> some View {
        modifier(Arriving(trigger: trigger, order: order))
    }
}

import SwiftUI

/// Applies an animation unless the system has been asked to reduce motion.
///
/// Reduce Motion is not a request for no feedback: the state still changes and
/// the view still updates. It asks that the change arrive rather than travel,
/// so the animation is dropped and the result is shown directly.
private struct MotionAware<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `animation(_:value:)` that honours Reduce Motion.
    func motionAware<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionAware(animation: animation, value: value))
    }
}

extension AnyTransition {
    /// A transition that keeps its fade but drops its movement under Reduce
    /// Motion. Something appearing is still worth showing; it just should not
    /// fly in from an edge.
    static func motionAware(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }

    /// One thing leaving and another arriving in its place, one after the
    /// other rather than on top of each other: what is going fades out first,
    /// and only once it has gone does what is coming fade in.
    ///
    /// The timings ride on the transition itself, so the staging holds
    /// whatever animation the surrounding transaction carries. `enterDelay`
    /// is how long the arrival waits; by default, exactly the exit.
    static func staged(exit: AnyTransition = .opacity,
                       enter: AnyTransition = .opacity,
                       enterDelay: TimeInterval = NookMotion.exitDuration,
                       reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: motionAware(enter, reduceMotion: reduceMotion)
                .animation(NookMotion.enter(reduceMotion: reduceMotion).delay(enterDelay)),
            removal: motionAware(exit, reduceMotion: reduceMotion)
                .animation(NookMotion.exit(reduceMotion: reduceMotion))
        )
    }
}

/// Nook's motion vocabulary.
///
/// New interactive features should use these timings and the motion-aware
/// helpers below rather than introducing one-off animations. This keeps the app
/// playful as it grows while guaranteeing the same Reduce Motion behaviour.
///
/// Every change is choreographed in stages — exit, shift, enter — and no two
/// stages run over each other. What leaves fades out first. What stays then
/// moves into its new place. Only once it has settled does what arrives fade
/// in. A stage a change does not need is skipped rather than waited out, which
/// is what `MotionChoreography` works out.
enum NookMotion {
    static let plop = Animation.spring(duration: 0.42, bounce: 0.28)
    static let reflow = Animation.spring(duration: shiftDuration, bounce: 0.08)
    static let interaction = Animation.smooth(duration: 0.16)
    static let presentation = Animation.smooth(duration: 0.22)
    static let reduced = Animation.easeOut(duration: reducedDuration)

    /// How long each stage takes. The shift is `reflow`'s own length, so a
    /// delay of one shift lands exactly as the spring settles.
    static let exitDuration: TimeInterval = 0.15
    static let shiftDuration: TimeInterval = 0.30
    static let enterDuration: TimeInterval = 0.22
    static let reducedDuration: TimeInterval = 0.12

    /// Something leaving: a short fade, quick enough that what follows is not
    /// kept waiting.
    static let exit = Animation.smooth(duration: exitDuration)
    /// Something arriving, once the stage is clear for it.
    static let enter = Animation.smooth(duration: enterDuration)

    static func exit(reduceMotion: Bool) -> Animation { reduceMotion ? reduced : exit }
    static func enter(reduceMotion: Bool) -> Animation { reduceMotion ? reduced : enter }
    static func reflow(reduceMotion: Bool) -> Animation { reduceMotion ? reduced : reflow }

    static func arrivalDelay(for index: Int) -> TimeInterval {
        0.045 * Double(min(max(index, 0), 8))
    }
}

/// Which stages a change to a collection actually needs, worked out from what
/// was showing and what is about to be.
///
/// A stage is only waited for when something is happening in it: an item
/// arriving into an otherwise untouched list fades in at once, while one
/// arriving as another leaves waits for the exit and for the survivors to
/// shift before it appears. Views read the delays off this rather than
/// guessing at constant ones, so nothing ever waits on an empty stage.
struct MotionChoreography: Equatable, Sendable {
    /// Something that was showing is gone.
    var removes = false
    /// Something that stays ends up somewhere else — because it was reordered,
    /// or because what left or arrived ahead of it moved it along.
    var shifts = false
    /// Something is showing that was not before.
    var inserts = false

    static let none = MotionChoreography()

    init(removes: Bool = false, shifts: Bool = false, inserts: Bool = false) {
        self.removes = removes
        self.shifts = shifts
        self.inserts = inserts
    }

    /// Reads the stages off the two orderings.
    init<ID: Hashable>(from old: [ID], to new: [ID]) {
        let oldSet = Set(old)
        let newSet = Set(new)

        var removes = false
        var removedAheadOfSurvivor = false
        var oldSurvivors: [ID] = []
        for id in old {
            if newSet.contains(id) {
                oldSurvivors.append(id)
                if removes { removedAheadOfSurvivor = true }
            } else {
                removes = true
            }
        }

        var inserts = false
        var insertedAheadOfSurvivor = false
        var newSurvivors: [ID] = []
        for id in new {
            if oldSet.contains(id) {
                newSurvivors.append(id)
                if inserts { insertedAheadOfSurvivor = true }
            } else {
                inserts = true
            }
        }

        self.removes = removes
        self.inserts = inserts
        self.shifts = removedAheadOfSurvivor || insertedAheadOfSurvivor || oldSurvivors != newSurvivors
    }

    /// How long the survivors wait before moving: the exit, if there is one.
    var shiftDelay: TimeInterval { removes ? NookMotion.exitDuration : 0 }

    /// How long what arrives waits before fading in: the exit and the shift,
    /// whichever of them are happening.
    var enterDelay: TimeInterval { shiftDelay + (shifts ? NookMotion.shiftDuration : 0) }

    func shiftDelay(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? (removes ? NookMotion.reducedDuration : 0) : shiftDelay
    }

    func enterDelay(reduceMotion: Bool) -> TimeInterval {
        guard reduceMotion else { return enterDelay }
        // Nothing moves under Reduce Motion, so there is no shift to wait for.
        return removes ? NookMotion.reducedDuration : 0
    }

    /// The survivors' move, held back until whatever is leaving has left.
    func shift(reduceMotion: Bool) -> Animation {
        NookMotion.reflow(reduceMotion: reduceMotion).delay(shiftDelay(reduceMotion: reduceMotion))
    }

    /// Item transitions that keep to the stages: a quick fade out, and a fade
    /// in that waits its turn.
    func itemTransition(exit: AnyTransition = .opacity,
                        enter: AnyTransition = .opacity,
                        reduceMotion: Bool) -> AnyTransition {
        .staged(exit: exit, enter: enter,
                enterDelay: enterDelay(reduceMotion: reduceMotion),
                reduceMotion: reduceMotion)
    }
}

/// Gives a newly-created gallery item its characteristic arrival without
/// replaying when an ordinary refresh reconstructs the surrounding view.
private struct PlopIn: ViewModifier {
    let trigger: Int?
    let order: Int
    /// How long the whole batch holds back before its first item lands — the
    /// exit and shift stages of whatever change brought it, so a new item
    /// never plops into a spot something else is still leaving.
    let delay: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible: Bool

    init(trigger: Int?, order: Int, delay: TimeInterval) {
        self.trigger = trigger
        self.order = order
        self.delay = delay
        _isVisible = State(initialValue: trigger == nil)
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .scaleEffect(reduceMotion || isVisible ? 1 : 0.72)
            .offset(y: reduceMotion || isVisible ? 0 : 10)
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
        let animation = reduceMotion
            ? NookMotion.reduced.delay(delay)
            : NookMotion.plop.delay(delay + NookMotion.arrivalDelay(for: order))
        withAnimation(animation) {
            isVisible = true
        }
    }
}

extension View {
    /// Plops a view in when `trigger` names an explicit creation/import batch.
    /// Passing `nil` displays it immediately, which is appropriate for initial
    /// loading, navigation, searching, and background refreshes.
    ///
    /// `delay` is the batch's wait for the stages ahead of it — usually the
    /// enclosing change's `MotionChoreography.enterDelay`.
    func plopIn(trigger: Int?, order: Int = 0, delay: TimeInterval = 0) -> some View {
        modifier(PlopIn(trigger: trigger, order: order, delay: delay))
    }
}

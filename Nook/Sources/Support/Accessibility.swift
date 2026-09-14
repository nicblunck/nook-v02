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
}

/// Nook's motion vocabulary.
///
/// New interactive features should use these timings and the motion-aware
/// helpers below rather than introducing one-off animations. This keeps the app
/// playful as it grows while guaranteeing the same Reduce Motion behaviour.
enum NookMotion {
    static let plop = Animation.spring(duration: 0.42, bounce: 0.28)
    static let reflow = Animation.spring(duration: 0.30, bounce: 0.08)
    static let interaction = Animation.smooth(duration: 0.16)
    static let presentation = Animation.smooth(duration: 0.22)
    static let reduced = Animation.easeOut(duration: 0.12)

    static func arrivalDelay(for index: Int) -> TimeInterval {
        0.045 * Double(min(max(index, 0), 8))
    }
}

/// Gives a newly-created gallery item its characteristic arrival without
/// replaying when an ordinary refresh reconstructs the surrounding view.
private struct PlopIn: ViewModifier {
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
            ? NookMotion.reduced
            : NookMotion.plop.delay(NookMotion.arrivalDelay(for: order))
        withAnimation(animation) {
            isVisible = true
        }
    }
}

extension View {
    /// Plops a view in when `trigger` names an explicit creation/import batch.
    /// Passing `nil` displays it immediately, which is appropriate for initial
    /// loading, navigation, searching, and background refreshes.
    func plopIn(trigger: Int?, order: Int = 0) -> some View {
        modifier(PlopIn(trigger: trigger, order: order))
    }
}

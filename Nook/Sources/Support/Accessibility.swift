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

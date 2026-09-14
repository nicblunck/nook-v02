import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct AppFocusLossModifier: ViewModifier {
    let action: @MainActor @Sendable () async -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.task {
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.willResignActiveNotification
            ) {
                guard !Task.isCancelled else { break }
                await action()
            }
        }
        #else
        AppFocusLossObserver(content: content, action: action)
        #endif
    }
}

#if !os(macOS)
private struct AppFocusLossObserver<Content: View>: View {
    let content: Content
    let action: @MainActor @Sendable () async -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .onChange(of: scenePhase) { _, phase in
                guard phase == .inactive || phase == .background else { return }
                Task { await action() }
            }
    }
}
#endif

extension View {
    func onAppFocusLoss(perform action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(AppFocusLossModifier(action: action))
    }

    /// Reports keyboard, pointer, scrolling, and touch input without taking
    /// any of those interactions away from the controls underneath it.
    func onAppActivity(perform action: @escaping @MainActor @Sendable () -> Void) -> some View {
        background {
            AppActivityObserver(action: action)
                .frame(width: 0, height: 0)
        }
    }
}

#if os(macOS)
private struct AppActivityObserver: NSViewRepresentable {
    let action: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.move(to: window)
        }
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {
        context.coordinator.action = action
        context.coordinator.move(to: view.window)
    }

    static func dismantleNSView(_ view: WindowTrackingView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var action: @MainActor @Sendable () -> Void
        private weak var window: NSWindow?
        private var monitor: Any?
        private var lastContinuousReport: TimeInterval = 0

        init(action: @escaping @MainActor @Sendable () -> Void) {
            self.action = action
        }

        func move(to window: NSWindow?) {
            self.window = window
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [
                .keyDown, .keyUp,
                .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .scrollWheel, .gesture, .magnify, .rotate, .swipe
            ]) { [weak self] event in
                self?.receive(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            window = nil
        }

        private func receive(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            switch event.type {
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                 .scrollWheel, .gesture, .magnify, .rotate, .swipe:
                reportContinuousActivity()
            default:
                action()
            }
        }

        /// Drag and scroll streams can arrive many times per display frame.
        /// Once per second is precise enough for a minimum 30-second timeout.
        private func reportContinuousActivity() {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastContinuousReport >= 1 else { return }
            lastContinuousReport = now
            action()
        }
    }

    @MainActor
    final class WindowTrackingView: NSView {
        var windowDidChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowDidChange?(window)
        }
    }
}
#else
private struct AppActivityObserver: UIViewRepresentable {
    let action: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.windowDidChange = { [weak coordinator = context.coordinator] window in
            coordinator?.move(to: window)
        }
        return view
    }

    func updateUIView(_ view: WindowTrackingView, context: Context) {
        context.coordinator.action = action
        context.coordinator.move(to: view.window)
    }

    static func dismantleUIView(_ view: WindowTrackingView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var action: @MainActor @Sendable () -> Void {
            didSet { recognizer.action = action }
        }
        private weak var window: UIWindow?
        private let recognizer: ActivityGestureRecognizer

        init(action: @escaping @MainActor @Sendable () -> Void) {
            self.action = action
            self.recognizer = ActivityGestureRecognizer(action: action)
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
        }

        func move(to window: UIWindow?) {
            guard self.window !== window else { return }
            self.window?.removeGestureRecognizer(recognizer)
            self.window = window
            window?.addGestureRecognizer(recognizer)
        }

        func stop() {
            window?.removeGestureRecognizer(recognizer)
            window = nil
        }
    }

    @MainActor
    final class WindowTrackingView: UIView {
        var windowDidChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowDidChange?(window)
        }
    }

    @MainActor
    final class ActivityGestureRecognizer: UIGestureRecognizer {
        var action: @MainActor @Sendable () -> Void
        private var lastContinuousReport: TimeInterval = 0

        init(action: @escaping @MainActor @Sendable () -> Void) {
            self.action = action
            super.init(target: nil, action: nil)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            action()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            reportContinuousActivity()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            action()
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .cancelled
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            action()
        }

        override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            reportContinuousActivity()
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            action()
            state = .failed
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            state = .cancelled
        }

        private func reportContinuousActivity() {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastContinuousReport >= 1 else { return }
            lastContinuousReport = now
            action()
        }
    }
}
#endif

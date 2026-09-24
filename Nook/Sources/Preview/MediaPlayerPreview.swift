import SwiftUI
import AVKit

/// Video and audio in AVKit's own player — the one QuickTime, Photos and the
/// TV app use — with its scrubber, Picture in Picture, full screen and speed
/// controls exactly as people know them.
///
/// This is the platform player view directly rather than SwiftUI's
/// `VideoPlayer`, which crashed here. The player is kept by the coordinator,
/// so a re-render — a selection change, a toolbar update — never restarts
/// what is playing; only a different file does.
#if canImport(AppKit)
import AppKit

struct MediaPlayerPreview: NSViewRepresentable {
    let url: URL
    let isVideo: Bool
    /// A page swiped past stops playing.
    let isCurrent: Bool
    /// Handed Option-Space while this is the page on screen.
    var keys: PreviewPageKeys? = nil

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // QuickTime's floating controls for a picture; audio has no picture
        // for them to float over, so its bar stays put.
        view.controlsStyle = isVideo ? .floating : .inline
        view.allowsPictureInPicturePlayback = isVideo
        view.showsFullScreenToggleButton = isVideo
        view.player = context.coordinator.player(for: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let player = context.coordinator.player(for: url)
        if view.player !== player { view.player = player }
        view.controlsStyle = isVideo ? .floating : .inline
        view.allowsPictureInPicturePlayback = isVideo
        view.showsFullScreenToggleButton = isVideo
        if !isCurrent { player.pause() }
        keys?.playPause = { [weak player] in
            guard let player else { return }
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        view.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private(set) var player: AVPlayer?

        func player(for url: URL) -> AVPlayer {
            if let player, (player.currentItem?.asset as? AVURLAsset)?.url == url { return player }
            player?.pause()
            let player = AVPlayer(url: url)
            self.player = player
            return player
        }
    }
}

#elseif canImport(UIKit)
import UIKit

struct MediaPlayerPreview: UIViewControllerRepresentable {
    let url: URL
    let isVideo: Bool
    /// A page swiped past stops playing.
    let isCurrent: Bool
    var onTap: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        // Plays with the ringer switched off, like every other media viewer.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let controller = AVPlayerViewController()
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.allowsPictureInPicturePlayback = isVideo
        controller.view.backgroundColor = .clear
        controller.player = context.coordinator.player(for: url)
        context.coordinator.installer.install(on: controller.view)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.installer.onTap = onTap
        let player = context.coordinator.player(for: url)
        if controller.player !== player { controller.player = player }
        controller.allowsPictureInPicturePlayback = isVideo
        if !isCurrent { player.pause() }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController,
                                          coordinator: Coordinator) {
        coordinator.player?.pause()
        controller.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private(set) var player: AVPlayer?
        let installer = PreviewGestureInstaller()

        func player(for url: URL) -> AVPlayer {
            if let player, (player.currentItem?.asset as? AVURLAsset)?.url == url { return player }
            player?.pause()
            let player = AVPlayer(url: url)
            self.player = player
            return player
        }
    }
}
#endif

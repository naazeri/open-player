import AppKit
import MediaPlayer

/// Headphone, keyboard and Control Center play/pause/next/previous. macOS sends these to the app
/// that last published "now playing" info, so playback state is kept up to date there as well.
final class NowPlaying {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (Double) -> Void
    }

    private var lastPublished: (title: String, duration: Double, paused: Bool, idle: Bool)?
    private var lastPosition = 0.0

    init(handlers: Handlers) {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping () -> Void) {
            command.isEnabled = true
            command.addTarget { _ in
                action()
                return .success
            }
        }
        on(center.playCommand, handlers.play)
        on(center.pauseCommand, handlers.pause)
        on(center.togglePlayPauseCommand, handlers.toggle)
        on(center.nextTrackCommand, handlers.next)
        on(center.previousTrackCommand, handlers.previous)
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            handlers.seek(event.positionTime)
            return .success
        }
        // Without published info macOS keeps sending the keys to Music.
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Called on every UI refresh; only republishes when something visible changed (or the
    /// position jumped, e.g. after a seek), since macOS extrapolates the time from the rate.
    func update(title: String?, duration: Double, position: Double, paused: Bool, idle: Bool, speed: Double) {
        let info = MPNowPlayingInfoCenter.default()
        let key = (title: title ?? "", duration: duration, paused: paused, idle: idle)
        let expected = lastPosition
        lastPosition = position
        if let last = lastPublished, last == key, abs(position - expected) < 2 { return }
        lastPublished = key
        if idle || title == nil {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : speed,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        info.playbackState = paused ? .paused : .playing
    }
}

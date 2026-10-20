import Foundation

/// Everything a key can trigger. Raw values are stable: they are stored in settings and backups.
public enum PlayerAction: String, CaseIterable, Codable, Sendable, Identifiable {
    public var id: String { rawValue }

    case playPause
    case seekBackward1, seekForward1
    case seekBackward2, seekForward2
    case seekBackward3, seekForward3
    case seekBackward4, seekForward4
    case previousFrame, nextFrame
    case jumpToStart, jumpToTime
    case speedDown, speedUp, speedReset
    case volumeUp, volumeDown, mute
    case previousFile, nextFile
    case addBookmark, showBookmarks
    case toggleFullscreen, exitFullscreen
    case toggleSubtitles, cycleSubtitle, loadSubtitle
    case subtitleDelayDown, subtitleDelayUp, subtitleDelayReset
    case subtitleSizeUp, subtitleSizeDown
    case cycleAudio, audioDelayDown, audioDelayUp, audioDelayReset
    case windowSizeHalf, windowSizeNormal, windowSizeOneAndHalf, windowSizeDouble
    case stayOnTop, showInfo
    case openFile, openFolder, closePlayback
    case preferences, playlist, saveFrame

    public enum Category: String, CaseIterable, Sendable {
        case playback = "Playback"
        case seeking = "Seeking"
        case audio = "Audio"
        case subtitles = "Subtitles"
        case bookmarks = "Bookmarks"
        case window = "Window"
        case app = "General"
    }

    public var category: Category {
        switch self {
        case .playPause, .speedDown, .speedUp, .speedReset, .previousFile, .nextFile, .saveFrame:
            return .playback
        case .seekBackward1, .seekForward1, .seekBackward2, .seekForward2, .seekBackward3, .seekForward3,
             .seekBackward4, .seekForward4, .previousFrame, .nextFrame, .jumpToStart, .jumpToTime:
            return .seeking
        case .volumeUp, .volumeDown, .mute, .cycleAudio, .audioDelayDown, .audioDelayUp, .audioDelayReset:
            return .audio
        case .toggleSubtitles, .cycleSubtitle, .loadSubtitle, .subtitleDelayDown, .subtitleDelayUp,
             .subtitleDelayReset, .subtitleSizeUp, .subtitleSizeDown:
            return .subtitles
        case .addBookmark, .showBookmarks:
            return .bookmarks
        case .toggleFullscreen, .exitFullscreen, .windowSizeHalf, .windowSizeNormal, .windowSizeOneAndHalf,
             .windowSizeDouble, .stayOnTop, .showInfo:
            return .window
        case .openFile, .openFolder, .closePlayback, .preferences, .playlist:
            return .app
        }
    }

    /// Title for menus and the shortcut editor. Seek titles include the configured step.
    public func title(seekSteps: [Double] = AppSettings.defaultSeekSteps) -> String {
        func step(_ index: Int) -> String {
            let value = index < seekSteps.count ? seekSteps[index] : AppSettings.defaultSeekSteps[index]
            return TimeFormat.stepLabel(value)
        }
        switch self {
        case .playPause: return "Play/Pause"
        case .seekBackward1: return "\(step(0)) Backward"
        case .seekForward1: return "\(step(0)) Forward"
        case .seekBackward2: return "\(step(1)) Backward"
        case .seekForward2: return "\(step(1)) Forward"
        case .seekBackward3: return "\(step(2)) Backward"
        case .seekForward3: return "\(step(2)) Forward"
        case .seekBackward4: return "\(step(3)) Backward"
        case .seekForward4: return "\(step(3)) Forward"
        case .previousFrame: return "Previous Frame"
        case .nextFrame: return "Next Frame"
        case .jumpToStart: return "Jump to Start"
        case .jumpToTime: return "Jump to Time…"
        case .speedDown: return "Decrease Speed"
        case .speedUp: return "Increase Speed"
        case .speedReset: return "Normal Speed"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .previousFile: return "Previous File"
        case .nextFile: return "Next File"
        case .addBookmark: return "Add Bookmark"
        case .showBookmarks: return "Show Bookmarks"
        case .toggleFullscreen: return "Toggle Fullscreen"
        case .exitFullscreen: return "Exit Fullscreen"
        case .toggleSubtitles: return "Show/Hide Subtitles"
        case .cycleSubtitle: return "Cycle Subtitle"
        case .loadSubtitle: return "Load Subtitle…"
        case .subtitleDelayDown: return "Subtitle Sync −0.5 s"
        case .subtitleDelayUp: return "Subtitle Sync +0.5 s"
        case .subtitleDelayReset: return "Reset Subtitle Sync"
        case .subtitleSizeUp: return "Increase Subtitle Size"
        case .subtitleSizeDown: return "Decrease Subtitle Size"
        case .cycleAudio: return "Cycle Audio Track"
        case .audioDelayDown: return "Audio Sync −0.05 s"
        case .audioDelayUp: return "Audio Sync +0.05 s"
        case .audioDelayReset: return "Reset Audio Sync"
        case .windowSizeHalf: return "Window 0.5×"
        case .windowSizeNormal: return "Window 1×"
        case .windowSizeOneAndHalf: return "Window 1.5×"
        case .windowSizeDouble: return "Window 2×"
        case .stayOnTop: return "Stay on Top"
        case .showInfo: return "Show Playback Info"
        case .openFile: return "Open File…"
        case .openFolder: return "Open Folder…"
        case .closePlayback: return "Close Playback"
        case .preferences: return "Settings…"
        case .playlist: return "Playlist"
        case .saveFrame: return "Save Current Frame"
        }
    }

    /// Actions that fire repeatedly while their key is held down.
    public var repeatsWhileHeld: Bool {
        switch self {
        case .seekBackward1, .seekForward1, .seekBackward2, .seekForward2, .seekBackward3, .seekForward3,
             .seekBackward4, .seekForward4, .previousFrame, .nextFrame, .speedDown, .speedUp,
             .volumeUp, .volumeDown, .subtitleDelayDown, .subtitleDelayUp, .subtitleSizeUp, .subtitleSizeDown,
             .audioDelayDown, .audioDelayUp:
            return true
        default:
            return false
        }
    }
}

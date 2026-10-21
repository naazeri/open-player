import Foundation

/// All user settings. Decoding is lenient: a missing or malformed field falls back to its default,
/// so settings files and backups from older or newer versions always load.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultSeekSteps: [Double] = [5, 30, 60, 300]

    // Seeking
    public var seekSteps: [Double] = AppSettings.defaultSeekSteps
    public var preciseSeeking = true

    // Keys
    public var keyRepeatDelay = 0.30
    public var keyRepeatInterval = 0.05
    /// Action raw value → combos, only for actions changed from the PotPlayer defaults.
    public var keyOverrides: [String: [String]] = [:]

    // Audio / speed
    public var volumeStep = 5.0
    public var volume = 100.0
    public var speedStep = 0.1
    public var mouseWheelVolume = true

    // Playback
    public var resumePlayback = true
    public var resizeWindowToVideo = true
    public var playlistScope: PlaylistScope = .allMedia
    /// When a file ends: show "next file plays in 3" with Cancel / Play Now, instead of playing at once.
    public var nextFileCountdown = true
    public var nextFileCountdownSeconds = 4
    public var hardwareDecoding = true

    // Subtitles
    public var autoLoadSubtitles = true
    /// "auto" (detect), or an iconv name such as "UTF-8" or "CP1256" (Persian/Arabic Windows).
    public var subtitleEncoding = "auto"
    /// Empty means mpv's default font.
    public var subtitleFont = ""
    public var subtitleScale = 1.0

    // Bookmarks
    /// Create a `.pbf` next to files that don't have one yet. Existing `.pbf` files are always kept in sync.
    public var createPBFFiles = false

    // Updates
    public var checkForUpdates = true

    // App
    /// Closing the player window stops playback but keeps the app running, so the next file opens faster.
    public var keepRunningAfterClose = true

    public init() {}

    public var keyMap: KeyMap { KeyMap(overrides: keyOverrides) }

    public func seekStep(_ index: Int) -> Double {
        index < seekSteps.count ? seekSteps[index] : Self.defaultSeekSteps[index]
    }

    enum CodingKeys: String, CodingKey {
        case seekSteps, preciseSeeking, keyRepeatDelay, keyRepeatInterval, keyOverrides
        case volumeStep, volume, speedStep, mouseWheelVolume
        case resumePlayback, resizeWindowToVideo, playlistScope, hardwareDecoding
        case autoLoadSubtitles, subtitleEncoding, subtitleFont, subtitleScale
        case createPBFFiles
        case checkForUpdates
        case keepRunningAfterClose
        case nextFileCountdown
        case nextFileCountdownSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        seekSteps = value(.seekSteps, d.seekSteps)
        preciseSeeking = value(.preciseSeeking, d.preciseSeeking)
        keyRepeatDelay = value(.keyRepeatDelay, d.keyRepeatDelay)
        keyRepeatInterval = value(.keyRepeatInterval, d.keyRepeatInterval)
        keyOverrides = value(.keyOverrides, d.keyOverrides)
        volumeStep = value(.volumeStep, d.volumeStep)
        volume = value(.volume, d.volume)
        speedStep = value(.speedStep, d.speedStep)
        mouseWheelVolume = value(.mouseWheelVolume, d.mouseWheelVolume)
        resumePlayback = value(.resumePlayback, d.resumePlayback)
        resizeWindowToVideo = value(.resizeWindowToVideo, d.resizeWindowToVideo)
        playlistScope = value(.playlistScope, d.playlistScope)
        hardwareDecoding = value(.hardwareDecoding, d.hardwareDecoding)
        autoLoadSubtitles = value(.autoLoadSubtitles, d.autoLoadSubtitles)
        subtitleEncoding = value(.subtitleEncoding, d.subtitleEncoding)
        subtitleFont = value(.subtitleFont, d.subtitleFont)
        subtitleScale = value(.subtitleScale, d.subtitleScale)
        createPBFFiles = value(.createPBFFiles, d.createPBFFiles)
        checkForUpdates = value(.checkForUpdates, d.checkForUpdates)
        keepRunningAfterClose = value(.keepRunningAfterClose, d.keepRunningAfterClose)
        nextFileCountdown = value(.nextFileCountdown, d.nextFileCountdown)
        nextFileCountdownSeconds = value(.nextFileCountdownSeconds, d.nextFileCountdownSeconds)
        sanitize()
    }

    /// Clamps values that would make the player misbehave.
    public mutating func sanitize() {
        var steps = seekSteps.prefix(4).map { max(0.1, min($0, 3600)) }
        while steps.count < 4 { steps.append(Self.defaultSeekSteps[steps.count]) }
        seekSteps = steps
        keyRepeatDelay = max(0.05, min(keyRepeatDelay, 2))
        keyRepeatInterval = max(0.01, min(keyRepeatInterval, 1))
        volumeStep = max(1, min(volumeStep, 50))
        volume = max(0, min(volume, 100))
        speedStep = max(0.01, min(speedStep, 1))
        subtitleScale = max(0.2, min(subtitleScale, 5))
        nextFileCountdownSeconds = max(1, min(nextFileCountdownSeconds, 30))
        if subtitleEncoding.trimmingCharacters(in: .whitespaces).isEmpty { subtitleEncoding = "auto" }
    }
}

/// Reads and writes `settings.json`.
public enum SettingsFile {
    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public static func save(_ settings: AppSettings, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

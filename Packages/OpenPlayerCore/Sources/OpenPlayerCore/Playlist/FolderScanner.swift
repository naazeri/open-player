import Foundation

public enum MediaKind: Sendable {
    case video, audio
}

public enum MediaTypes {
    public static let video: Set<String> = [
        "mp4", "m4v", "mkv", "avi", "mov", "wmv", "flv", "webm", "mpg", "mpeg", "m2ts", "mts", "ts",
        "vob", "3gp", "3g2", "ogv", "rm", "rmvb", "asf", "divx", "f4v", "mxf", "dv", "y4m", "hevc",
    ]
    public static let audio: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg", "oga", "opus", "wma", "aiff", "aif", "ape",
        "mka", "ac3", "eac3", "dts", "alac", "wv", "mpc", "amr", "caf",
    ]
    public static let subtitles: Set<String> = ["srt", "ass", "ssa", "sub", "vtt", "smi", "sami", "idx", "sup"]

    public static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if video.contains(ext) { return .video }
        if audio.contains(ext) { return .audio }
        return nil
    }

    public static func isMedia(_ url: URL) -> Bool { kind(of: url) != nil }
    public static func isSubtitle(_ url: URL) -> Bool { subtitles.contains(url.pathExtension.lowercased()) }
}

/// Which sibling files join the playlist when one file is opened.
public enum PlaylistScope: String, Codable, CaseIterable, Sendable {
    /// Every video and audio file in the folder.
    case allMedia
    /// Only videos when a video was opened, only audio when audio was opened.
    case sameKind
    /// Only files with the same extension (PotPlayer's classic behaviour).
    case sameExtension

    public var title: String {
        switch self {
        case .allMedia: return "All video and audio files"
        case .sameKind: return "Same kind (video or audio)"
        case .sameExtension: return "Same extension only"
        }
    }
}

public enum FolderScanner {
    /// The playlist for an opened file: matching files from its folder, naturally sorted.
    /// The opened file is always included, even when its extension is unknown.
    public static func playlist(for file: URL, scope: PlaylistScope) -> [URL] {
        let folder = file.deletingLastPathComponent()
        var items = mediaFiles(in: folder, matching: file, scope: scope)
        if !items.contains(where: { $0.standardizedFileURL == file.standardizedFileURL }) {
            items.append(file)
            items = naturalSorted(items)
        }
        return items
    }

    /// All media files in `folder` (non-recursive). With a `reference` the scope filter applies.
    public static func mediaFiles(in folder: URL, matching reference: URL? = nil, scope: PlaylistScope = .allMedia) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        let referenceExt = reference?.pathExtension.lowercased()
        let referenceKind = reference.flatMap(MediaTypes.kind(of:))

        let files = contents.filter { url in
            let name = url.lastPathComponent
            // AppleDouble files ("._name") appear on exFAT/NTFS drives.
            if name.hasPrefix("._") || name.hasPrefix(".") { return false }
            if (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) != true { return false }
            guard let kind = MediaTypes.kind(of: url) else { return false }
            guard reference != nil else { return true }
            switch scope {
            case .allMedia: return true
            case .sameKind: return referenceKind == nil || kind == referenceKind
            case .sameExtension: return url.pathExtension.lowercased() == referenceExt
            }
        }
        return naturalSorted(files)
    }

    /// Finder-like order: "ep2" before "ep10", case-insensitive, works for Persian names.
    public static func naturalSorted(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

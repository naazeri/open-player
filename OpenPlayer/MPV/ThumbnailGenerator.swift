import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Grabs one frame from a file with a short-lived, software-decoding mpv instance.
/// The playing instance uses zero-copy VideoToolbox frames, which mpv cannot screenshot.
enum ThumbnailGenerator {
    private static let queue = DispatchQueue(label: "openplayer.thumbnails", qos: .utility)

    static func generate(for url: URL, at seconds: Double, maxWidth: Int = 192, completion: @escaping (Data?) -> Void) {
        queue.async {
            let data = grab(url: url, seconds: seconds, maxWidth: maxWidth)
            DispatchQueue.main.async { completion(data) }
        }
    }

    private static func grab(url: URL, seconds: Double, maxWidth: Int) -> Data? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openplayer-thumb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        guard let handle = mpv_create() else { return nil }
        defer { mpv_terminate_destroy(handle) }
        let options: [(String, String)] = [
            ("config", "no"), ("terminal", "no"), ("idle", "no"),
            ("vo", "image"), ("vo-image-format", "jpg"), ("vo-image-jpeg-quality", "80"),
            ("vo-image-outdir", folder.path),
            ("ao", "null"), ("audio", "no"), ("sub", "no"), ("hwdec", "no"),
            ("hr-seek", "yes"), ("start", String(max(0, seconds))), ("frames", "1"),
            ("vf", "scale=\(maxWidth):-2"),
        ]
        for (name, value) in MPVPlayer.disabledScriptOptions + options { MPVPlayer.setOption(handle, name, value) }
        guard mpv_initialize(handle) >= 0 else { return nil }

        var args: [UnsafeMutablePointer<CChar>?] = [strdup("loadfile"), strdup(url.path), nil]
        defer { args.forEach { free($0) } }
        let status = args.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                mpv_command(handle, $0)
            }
        }
        guard status >= 0 else { return nil }

        let deadline = Date().addingTimeInterval(15)
        loop: while Date() < deadline {
            guard let event = mpv_wait_event(handle, 1) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN: break loop
            default: continue
            }
        }

        guard let file = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "jpg" }) else { return nil }
        return try? Data(contentsOf: file)
    }
}

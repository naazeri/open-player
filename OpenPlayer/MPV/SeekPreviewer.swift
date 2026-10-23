import CoreGraphics
import Foundation

/// Frames for the seek bar's hover preview (like YouTube), from a second, paused mpv instance
/// that decodes small frames of the current file. Keyframe seeks are fast but can be a few
/// seconds off; exact seeks decode up to the requested frame. Only one request runs at a time
/// and a newer one replaces a waiting one, so moving the mouse quickly never builds a backlog.
final class SeekPreviewer {
    /// Width of the decoded frames in pixels (2× the preview's width in points).
    static let pixelWidth = 352

    private let queue = DispatchQueue(label: "openplayer.seekpreview", qos: .userInitiated)
    // Main thread only.
    private var pending: (url: URL, time: Double, exact: Bool, completion: (CGImage?) -> Void)?
    private var isRunning = false
    private var generation = 0
    /// The decoder holds a few full-size frames (a lot for 4K), so it goes when the mouse has
    /// been away from the seek bar for a while; coming back costs one file open (~0.1 s).
    private var idleTimer: Timer?
    private static let idleTimeout: TimeInterval = 15
    // `queue` only.
    private var handle: OpaquePointer?
    private var loadedURL: URL?
    private var cache: [String: CGImage] = [:]
    private var cacheOrder: [String] = []
    private static let cacheLimit = 60

    deinit {
        if let handle { mpv_terminate_destroy(handle) }
    }

    /// `completion` runs on the main thread (not after `close()`).
    func request(url: URL, time: Double, exact: Bool, completion: @escaping (CGImage?) -> Void) {
        pending = (url, time, exact, completion)
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) { [weak self] _ in
            self?.close()
        }
        startNext()
    }

    /// Drops waiting requests and frees the mpv instance, which also closes the file.
    func close() {
        idleTimer?.invalidate()
        idleTimer = nil
        generation += 1
        pending = nil
        queue.async { self.destroy() }
    }

    private func startNext() {
        guard !isRunning, let job = pending else { return }
        pending = nil
        isRunning = true
        let started = generation
        queue.async {
            let image = self.frame(url: job.url, time: job.time, exact: job.exact)
            DispatchQueue.main.async {
                self.isRunning = false
                // Delivered even when a newer request waits: while the mouse keeps moving, a
                // slightly older frame is better than none.
                if started == self.generation { job.completion(image) }
                self.startNext()
            }
        }
    }

    // MARK: mpv (on `queue`)

    private func frame(url: URL, time: Double, exact: Bool) -> CGImage? {
        // Keyframe results are shared by nearby times; exact ones only by the same tenth of a second.
        let key = exact ? "e\(Int(time * 10))" : "k\(Int(time / 2))"
        if url == loadedURL, let image = cache[key] { return image }
        guard load(url) else { return nil }
        let target = String(format: "%.3f", max(0, time))
        guard command(["seek", target, exact ? "absolute+exact" : "absolute+keyframes"]) >= 0,
              wait(for: MPV_EVENT_PLAYBACK_RESTART, timeout: 3),
              let image = screenshot() else { return nil }
        cache[key] = image
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        return image
    }

    private func load(_ url: URL) -> Bool {
        if url == loadedURL, handle != nil { return true }
        if handle == nil, !create() { return false }
        loadedURL = nil
        cache.removeAll()
        cacheOrder.removeAll()
        // Paused, so the first frame is decoded and then nothing else.
        guard command(["loadfile", url.path]) >= 0, wait(for: MPV_EVENT_PLAYBACK_RESTART, timeout: 5) else {
            destroy()
            return false
        }
        loadedURL = url
        return true
    }

    private func create() -> Bool {
        guard let handle = mpv_create() else { return false }
        let options: [(String, String)] = [
            ("config", "no"), ("terminal", "no"), ("idle", "yes"), ("pause", "yes"), ("keep-open", "always"),
            ("vo", "null"), ("ao", "null"), ("audio", "no"), ("sub", "no"), ("osd-level", "0"),
            // Software decoding with shortcuts that don't show at this size: measured about twice
            // as fast as VideoToolbox here, since an exact seek decodes many frames it never shows.
            ("hwdec", "no"), ("vd-lavc-fast", "yes"), ("vd-lavc-skiploopfilter", "all"), ("vd-lavc-skipframe", "nonref"),
            ("vf", "scale=w=\(Self.pixelWidth):h=-2:flags=bilinear"),
            // No reading ahead: each preview only needs the frames up to the one shown.
            ("cache", "no"), ("demuxer-readahead-secs", "0"),
            ("input-default-bindings", "no"), ("input-vo-keyboard", "no"),
        ]
        for (name, value) in MPVPlayer.disabledScriptOptions + options { MPVPlayer.setOption(handle, name, value) }
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            return false
        }
        self.handle = handle
        return true
    }

    private func destroy() {
        if let handle { mpv_terminate_destroy(handle) }
        handle = nil
        loadedURL = nil
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func wait(for eventID: mpv_event_id, timeout: Double) -> Bool {
        guard let handle else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let event = mpv_wait_event(handle, deadline.timeIntervalSinceNow) else { continue }
            switch event.pointee.event_id {
            case eventID: return true
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN: return false
            default: continue
            }
        }
        return false
    }

    @discardableResult
    private func command(_ args: [String], result: UnsafeMutablePointer<mpv_node>? = nil) -> Int32 {
        guard let handle else { return -1 }
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }
        return cArgs.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { args in
                result.map { mpv_command_ret(handle, args, $0) } ?? mpv_command(handle, args)
            }
        }
    }

    /// The current (already scaled) frame as an image; mpv returns it as "bgr0" pixels.
    private func screenshot() -> CGImage? {
        var node = mpv_node()
        guard command(["screenshot-raw", "video"], result: &node) >= 0 else { return nil }
        defer { mpv_free_node_contents(&node) }
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list?.pointee else { return nil }

        var width = 0, height = 0, stride = 0
        var pixels: Data?
        for i in 0..<Int(list.num) {
            guard let key = list.keys?[i].map({ String(cString: $0) }), let value = list.values?[i] else { continue }
            switch key {
            case "w": width = Int(value.u.int64)
            case "h": height = Int(value.u.int64)
            case "stride": stride = Int(value.u.int64)
            case "data":
                if value.format == MPV_FORMAT_BYTE_ARRAY, let bytes = value.u.ba?.pointee, let data = bytes.data {
                    pixels = Data(bytes: data, count: bytes.size)
                }
            default: break
            }
        }
        guard width > 0, height > 0, stride >= width * 4, let pixels, pixels.count >= stride * height,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

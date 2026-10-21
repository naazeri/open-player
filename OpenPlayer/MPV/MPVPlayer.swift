import Foundation

enum MPVValue {
    case none
    case flag(Bool)
    case int(Int64)
    case double(Double)
    case string(String)

    var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    var bool: Bool? {
        if case .flag(let v) = self { return v }
        return nil
    }
}

enum MPVEndReason {
    case eof, stop, quit, error(String), redirect
}

protocol MPVPlayerDelegate: AnyObject {
    func mpvPropertyChanged(_ name: String, _ value: MPVValue)
    func mpvFileLoaded()
    func mpvEndFile(_ reason: MPVEndReason)
    func mpvVideoReconfigured()
    /// `script-message` from an IPC client (debug builds use this for automated checks).
    func mpvClientMessage(_ args: [String])
}

/// Thin wrapper around a libmpv handle. Events are delivered to the delegate on the main thread.
final class MPVPlayer {
    private(set) var handle: OpaquePointer?
    weak var delegate: MPVPlayerDelegate?
    private let eventQueue = DispatchQueue(label: "openplayer.mpv.events")

    static let observedProperties: [(String, mpv_format)] = [
        ("pause", MPV_FORMAT_FLAG),
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("volume", MPV_FORMAT_DOUBLE),
        ("mute", MPV_FORMAT_FLAG),
        ("speed", MPV_FORMAT_DOUBLE),
        ("idle-active", MPV_FORMAT_FLAG),
        ("sub-delay", MPV_FORMAT_DOUBLE),
        ("eof-reached", MPV_FORMAT_FLAG),
    ]

    /// Built-in mpv scripts the app doesn't use. Playback waits until every loaded script has
    /// started, so leaving them out makes files open sooner (also used by `ThumbnailGenerator`).
    static let disabledScriptOptions: [(String, String)] = [
        ("load-scripts", "no"), ("osc", "no"), ("ytdl", "no"), ("load-stats-overlay", "no"),
        ("load-console", "no"), ("load-select", "no"), ("load-commands", "no"),
        ("load-context-menu", "no"), ("load-positioning", "no"), ("load-auto-profiles", "no"),
    ]

    /// Sets an option before `mpv_initialize`; debug builds report names mpv doesn't know.
    static func setOption(_ handle: OpaquePointer?, _ name: String, _ value: String) {
        let status = mpv_set_option_string(handle, name, value)
        #if DEBUG
        if status < 0 { NSLog("mpv rejected option %@=%@: %s", name, value, mpv_error_string(status)) }
        #endif
    }

    init() {
        handle = mpv_create()
        guard handle != nil else { fatalError("mpv_create failed") }
        for (name, value) in Self.disabledScriptOptions { setOption(name, value) }

        // Rendering goes through the render API into our own layer.
        setOption("vo", "libmpv")
        setOption("hwdec", "auto-safe")
        setOption("idle", "yes")
        // Stay paused on the last frame when a file ends; the app decides what plays next.
        setOption("keep-open", "yes")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("audio-display", "no")
        setOption("osd-on-seek", "msg-bar")
        setOption("osd-duration", "1200")
        setOption("osd-font-size", "34")
        setOption("osd-border-size", "2")
        setOption("osd-bar-h", "2.5")
        setOption("osd-align-x", "left")
        setOption("osd-align-y", "top")
        setOption("screenshot-format", "jpg")
        setOption("screenshot-jpeg-quality", "92")
        setOption("volume-max", "100")
        setOption("sub-auto", "fuzzy")
        setOption("sub-codepage", "auto")
        setOption("subs-fallback", "yes")
        setOption("demuxer-max-bytes", "150MiB")
        setOption("terminal", "no")
        #if DEBUG
        mpv_request_log_messages(handle, "warn")
        // Lets scripts inspect a debug build: OPEN_PLAYER_IPC_SOCKET=/path/to.sock
        if let socket = ProcessInfo.processInfo.environment["OPEN_PLAYER_IPC_SOCKET"] {
            setOption("input-ipc-server", socket)
        }
        #endif

        let status = mpv_initialize(handle)
        if status < 0 { fatalError("mpv_initialize failed: \(String(cString: mpv_error_string(status)))") }

        for (name, format) in Self.observedProperties {
            mpv_observe_property(handle, 0, name, format)
        }

        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            let player = Unmanaged<MPVPlayer>.fromOpaque(context).takeUnretainedValue()
            player.eventQueue.async { player.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Call after the render context is freed.
    func destroy() {
        guard let handle else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        self.handle = nil
        mpv_terminate_destroy(handle)
    }

    // MARK: Commands

    /// Runs a command without OSD and without property expansion (safe for file paths).
    @discardableResult
    func command(_ args: [String]) -> Int32 {
        guard let handle else { return -1 }
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.forEach { free($0) } }
        return cArgs.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                mpv_command(handle, $0)
            }
        }
    }

    /// Runs an input.conf style command: OSD feedback and `${property}` expansion are enabled.
    @discardableResult
    func commandString(_ command: String) -> Int32 {
        guard let handle else { return -1 }
        return mpv_command_string(handle, command)
    }

    /// Shows a message on the video OSD.
    func showText(_ text: String, durationMs: Int = 1500) {
        command(["show-text", text, String(durationMs)])
    }

    // MARK: Properties

    func setOption(_ name: String, _ value: String) {
        guard let handle else { return }
        Self.setOption(handle, name, value)
    }

    func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let handle else { return }
        var number = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &number)
    }

    func getDouble(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func getInt(_ name: String) -> Int64? {
        guard let handle else { return nil }
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    func getFlag(_ name: String) -> Bool? {
        guard let handle else { return nil }
        var value: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    func getString(_ name: String) -> String? {
        guard let handle, let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    // MARK: Events

    private func drainEvents() {
        while let handle {
            guard let event = mpv_wait_event(handle, 0) else { break }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { break }
            dispatch(event.pointee)
            if id == MPV_EVENT_SHUTDOWN { break }
        }
    }

    private func dispatch(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            let value = Self.parse(property)
            DispatchQueue.main.async { self.delegate?.mpvPropertyChanged(name, value) }

        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { self.delegate?.mpvFileLoaded() }

        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let info = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            let reason: MPVEndReason
            switch info.reason {
            case MPV_END_FILE_REASON_EOF: reason = .eof
            case MPV_END_FILE_REASON_QUIT: reason = .quit
            case MPV_END_FILE_REASON_ERROR: reason = .error(String(cString: mpv_error_string(info.error)))
            case MPV_END_FILE_REASON_REDIRECT: reason = .redirect
            default: reason = .stop
            }
            DispatchQueue.main.async { self.delegate?.mpvEndFile(reason) }

        case MPV_EVENT_VIDEO_RECONFIG:
            DispatchQueue.main.async { self.delegate?.mpvVideoReconfigured() }

        case MPV_EVENT_CLIENT_MESSAGE:
            guard let data = event.data else { return }
            let message = data.assumingMemoryBound(to: mpv_event_client_message.self).pointee
            var args: [String] = []
            for index in 0..<Int(message.num_args) {
                if let arg = message.args[index] { args.append(String(cString: arg)) }
            }
            // Run loop modes include menu tracking, so debug messages also reach an open menu.
            RunLoop.main.perform(inModes: [.common, .eventTracking]) { self.delegate?.mpvClientMessage(args) }
            CFRunLoopWakeUp(CFRunLoopGetMain())

        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            NSLog("[mpv] %@: %@", String(cString: message.prefix),
                  String(cString: message.text).trimmingCharacters(in: .newlines))

        default:
            break
        }
    }

    private static func parse(_ property: mpv_event_property) -> MPVValue {
        guard let data = property.data else { return .none }
        switch property.format {
        case MPV_FORMAT_FLAG: return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_INT64: return .int(data.assumingMemoryBound(to: Int64.self).pointee)
        case MPV_FORMAT_DOUBLE: return .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_STRING:
            guard let string = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return .none }
            return .string(String(cString: string))
        default: return .none
        }
    }
}

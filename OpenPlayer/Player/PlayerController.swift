import AppKit
import Combine
import OpenPlayerCore
import UniformTypeIdentifiers

/// Snapshot of what mpv is doing, read by the control bar.
final class PlaybackState {
    var isIdle = true
    var isPaused = true
    var position = 0.0
    var duration = 0.0
    var volume = 100.0
    var isMuted = false
    var speed = 1.0
    var hasVideo = false
    var hasPrevious = false
    var hasNext = false
    var bookmarkPositions: [Double] = []
}

/// The current playlist (observed by the playlist panel).
final class PlaylistModel: ObservableObject {
    @Published var items: [URL] = []
    @Published var currentIndex: Int?

    var currentURL: URL? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }
}

/// Connects mpv, the window, the playlist, bookmarks and settings, and executes every player action.
final class PlayerController: NSObject, MPVPlayerDelegate {
    let settings: SettingsStore
    let mpv = MPVPlayer()
    let bookmarks: BookmarkService
    let playlist = PlaylistModel()
    let state = PlaybackState()
    private(set) var windowController: PlayerWindowController!
    private var keyHandler: KeyInputHandler!

    var onShowSettings: (() -> Void)?
    var onTogglePlaylist: (() -> Void)?
    var onShowBookmarkManager: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var appliedSettings: AppSettings?
    private var menuBuilder: BookmarkMenuBuilder?
    private var activeMenu: NSMenu?
    private var renderScheduled = false
    private var lastRenderedPosition = -1.0
    private var pendingResize = false
    private var pendingStartMessage: String?
    private var lastResumeSave = Date.distantPast
    private var lastSpeed = 1.0
    private var scrollAccumulator: CGFloat = 0
    private var currentHasVideo = false

    private var currentURL: URL? { playlist.currentURL }

    init(settings: SettingsStore, library: LibraryStore) {
        self.settings = settings
        bookmarks = BookmarkService(store: library, settings: settings)
        super.init()

        windowController = PlayerWindowController(player: mpv)
        mpv.delegate = self
        mpv.setDouble("volume", settings.value.volume)
        state.volume = settings.value.volume

        keyHandler = KeyInputHandler { [weak self] action in self?.perform(action) }
        keyHandler.accepts = { [weak self] event in
            guard let window = self?.windowController.window else { return false }
            return event.window === window && !(window.firstResponder is NSText)
        }
        keyHandler.start()

        wireUpWindow()
        bookmarks.onChange = { [weak self] in
            self?.refreshBookmarkMarkers()
            NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
        }
        settings.$value.sink { [weak self] value in self?.apply(value) }.store(in: &cancellables)
        render()
    }

    func showWindow() {
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    private func wireUpWindow() {
        let controlBar = windowController.controlBar
        controlBar.onAction = { [weak self] action in self?.perform(action) }
        controlBar.onVolumeChange = { [weak self] volume in self?.setVolume(volume, showOSD: false) }
        controlBar.seekBar.onSeek = { [weak self] time, final in
            self?.mpv.command(["seek", String(time), final ? "absolute+exact" : "absolute+keyframes"])
        }

        let video = windowController.videoView
        video.onClick = { [weak self] in
            guard let self, !self.state.isIdle else { return }
            self.togglePause()
        }
        video.onDoubleClick = { [weak self] in self?.windowController.toggleFullscreen() }
        video.onScroll = { [weak self] event in self?.handleScroll(event) }

        windowController.onDropURLs = { [weak self] urls in self?.open(urls) }
        windowController.onWillClose = { NSApp.terminate(nil) }
        windowController.onResignKey = { [weak self] in self?.keyHandler.stopRepeating() }
        windowController.contextMenuProvider = { [weak self] in self?.makeContextMenu() ?? NSMenu() }
    }

    /// Pushes changed settings into mpv and the key handler.
    private func apply(_ value: AppSettings) {
        let old = appliedSettings
        appliedSettings = value
        keyHandler.keyMap = value.keyMap
        keyHandler.repeatDelay = value.keyRepeatDelay
        keyHandler.repeatInterval = value.keyRepeatInterval

        if old?.hardwareDecoding != value.hardwareDecoding {
            mpv.setString("hwdec", value.hardwareDecoding ? "auto-safe" : "no")
        }
        if old?.preciseSeeking != value.preciseSeeking {
            mpv.setString("hr-seek", value.preciseSeeking ? "yes" : "default")
        }
        if old?.subtitleEncoding != value.subtitleEncoding {
            mpv.setString("sub-codepage", value.subtitleEncoding)
        }
        if old?.autoLoadSubtitles != value.autoLoadSubtitles {
            mpv.setString("sub-auto", value.autoLoadSubtitles ? "fuzzy" : "no")
        }
        if old?.subtitleFont != value.subtitleFont {
            mpv.setString("sub-font", value.subtitleFont.isEmpty ? "sans-serif" : value.subtitleFont)
        }
        if old?.subtitleScale != value.subtitleScale {
            mpv.setDouble("sub-scale", value.subtitleScale)
        }
    }

    // MARK: Opening

    func open(_ urls: [URL], startAt: Double? = nil) {
        let fileManager = FileManager.default
        func isDirectory(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }

        if urls.count == 1, let url = urls.first {
            if isDirectory(url) {
                let items = FolderScanner.mediaFiles(in: url)
                guard !items.isEmpty else { return showError("No video or audio files in “\(url.lastPathComponent)”.") }
                setPlaylist(items, play: 0)
            } else if MediaTypes.isSubtitle(url), currentURL != nil {
                loadSubtitle(url)
            } else {
                let items = FolderScanner.playlist(for: url, scope: settings.value.playlistScope)
                let index = items.firstIndex { $0.standardizedFileURL == url.standardizedFileURL } ?? 0
                setPlaylist(items, play: index, startAt: startAt)
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return
        }

        var items: [URL] = []
        for url in urls {
            if isDirectory(url) {
                items += FolderScanner.mediaFiles(in: url)
            } else if MediaTypes.isMedia(url) {
                items.append(url)
            }
        }
        if let subtitle = urls.first(where: MediaTypes.isSubtitle), items.isEmpty, currentURL != nil {
            return loadSubtitle(subtitle)
        }
        guard !items.isEmpty else { return }
        setPlaylist(items, play: 0)
    }

    private func setPlaylist(_ items: [URL], play index: Int, startAt: Double? = nil) {
        playlist.items = items
        play(index: index, startAt: startAt)
    }

    func play(index: Int, startAt: Double? = nil) {
        guard playlist.items.indices.contains(index) else { return }
        saveResumePosition()
        let url = playlist.items[index]
        playlist.currentIndex = index
        bookmarks.syncFromPBF(for: url)

        var start = startAt
        pendingStartMessage = nil
        if start == nil, settings.value.resumePlayback,
           let resume = bookmarks.store.resumePosition(for: BookmarkService.key(for: url)), resume > 5 {
            start = resume
            pendingStartMessage = "Resumed at \(TimeFormat.long(resume))  (Backspace: start over)"
        }

        var command = ["loadfile", url.path, "replace"]
        if let start { command += ["-1", "start=\(start)"] }
        mpv.command(command)
        mpv.setFlag("pause", false)

        pendingResize = false
        state.isIdle = false
        state.position = start ?? 0
        state.duration = 0
        windowController.setTitle(for: url)
        refreshBookmarkMarkers()
        render()
    }

    private func playRelative(_ offset: Int) {
        guard let index = playlist.currentIndex else { return }
        let target = index + offset
        if playlist.items.indices.contains(target) {
            play(index: target)
        } else {
            mpv.showText(offset > 0 ? "This is the last file" : "This is the first file")
        }
    }

    func closePlayback() {
        saveResumePosition()
        mpv.command(["stop"])
        playlist.currentIndex = nil
        state.isIdle = true
        state.position = 0
        state.duration = 0
        currentHasVideo = false
        windowController.exitFullscreen()
        windowController.setMode(.idle)
        refreshBookmarkMarkers()
        render()
    }

    // MARK: MPVPlayerDelegate

    func mpvPropertyChanged(_ name: String, _ value: MPVValue) {
        switch name {
        case "pause":
            let paused = value.bool ?? false
            state.isPaused = paused
            windowController.setPaused(paused)
            if paused { saveResumePosition() }
        case "time-pos":
            guard let position = value.double else { return }
            state.position = position
            if Date().timeIntervalSince(lastResumeSave) > 5 { saveResumePosition() }
            // time-pos changes every frame; redraw the bar about four times a second.
            if abs(position - lastRenderedPosition) < 0.25 { return }
        case "duration":
            state.duration = value.double ?? 0
        case "volume":
            state.volume = value.double ?? state.volume
        case "mute":
            state.isMuted = value.bool ?? false
        case "speed":
            state.speed = value.double ?? 1
        default:
            return
        }
        render()
    }

    func mpvFileLoaded() {
        let videoTrack = mpv.getInt("current-tracks/video/id")
        let isImage = mpv.getFlag("current-tracks/video/image") ?? false
        let isAlbumArt = mpv.getFlag("current-tracks/video/albumart") ?? false
        currentHasVideo = videoTrack != nil && !isImage && !isAlbumArt
        state.hasVideo = currentHasVideo
        // The new video's size arrives with the next VIDEO_RECONFIG; at this point mpv may still
        // report the previous file's dimensions.
        pendingResize = currentHasVideo
        if !currentHasVideo { windowController.setMode(.audio) }
        if currentHasVideo, let url = currentURL { bookmarks.generateMissingThumbnails(for: url) }
        if let message = pendingStartMessage {
            pendingStartMessage = nil
            mpv.showText(message, durationMs: 2500)
        }
        render()
    }

    func mpvVideoReconfigured() {
        guard currentHasVideo, let width = mpv.getInt("dwidth"), let height = mpv.getInt("dheight"),
              width > 0, height > 0 else { return }
        let size = NSSize(width: CGFloat(width), height: CGFloat(height))
        // Coming from the compact audio window always needs a real size.
        let fromAudio = windowController.mode == .audio
        if pendingResize || fromAudio || windowController.mode == .idle {
            pendingResize = false
            windowController.setMode(.video(size), resize: settings.value.resizeWindowToVideo || fromAudio)
        } else if windowController.mode != .video(size) {
            windowController.setMode(.video(size), resize: false)
        }
    }

    func mpvEndFile(_ reason: MPVEndReason) {
        switch reason {
        case .eof:
            if let url = currentURL { bookmarks.store.clearResumePosition(path: BookmarkService.key(for: url)) }
            if let index = playlist.currentIndex, index + 1 < playlist.items.count {
                play(index: index + 1)
            } else {
                finishPlayback()
            }
        case .error(let message):
            let name = currentURL?.lastPathComponent ?? "file"
            finishPlayback()
            showError("Can't play “\(name)”: \(message)")
        case .stop, .quit, .redirect:
            break
        }
    }

    /// Debug builds accept `script-message op-action <action>`, `op-open <path>`,
    /// `op-key <down|up|repeat> <combo>` and `op-dump` over the IPC socket.
    func mpvClientMessage(_ args: [String]) {
        #if DEBUG
        guard let command = args.first else { return }
        switch command {
        case "op-action":
            if args.count > 1, let action = PlayerAction(rawValue: args[1]) { perform(action) }
        case "op-open":
            open(args.dropFirst().map { URL(fileURLWithPath: $0) })
        case "op-key":
            guard args.count > 2, let combo = KeyCombo(string: args[2]) else { return }
            var flags: NSEvent.ModifierFlags = []
            if combo.modifiers.contains(.control) { flags.insert(.control) }
            if combo.modifiers.contains(.option) { flags.insert(.option) }
            if combo.modifiers.contains(.shift) { flags.insert(.shift) }
            if combo.modifiers.contains(.command) { flags.insert(.command) }
            keyHandler.simulate(keyCode: combo.keyCode, modifiers: flags, down: args[1] != "up",
                                repeat: args[1] == "repeat", window: windowController.window)
        case "op-menu":
            showBookmarkMenu()
        case "op-submenu":
            // Pops one file's bookmark submenu on its own so it can be inspected without hovering.
            guard args.count > 1, let index = Int(args[1]), let view = windowController.window?.contentView else { return }
            let fileItems = makeBookmarkMenu().items.filter { $0.submenu != nil }
            guard fileItems.indices.contains(index), let submenu = fileItems[index].submenu else { return }
            fileItems[index].submenu = nil
            activeMenu = submenu
            submenu.popUp(positioning: nil, at: NSPoint(x: 20, y: view.bounds.height - 20), in: view)
        case "op-window":
            switch args.count > 1 ? args[1] : "" {
            case "settings": onShowSettings?()
            case "shortcuts": NSApp.sendAction(Selector(("showShortcuts:")), to: NSApp.delegate, from: nil)
            case "manager": onShowBookmarkManager?()
            case "playlist": onTogglePlaylist?()
            default: break
            }
        case "op-close-menus":
            activeMenu?.cancelTracking()
            activeMenu = nil
        case "op-dump":
            let files = bookmarks.bookmarkedFiles().map { file in
                "\(file.fileName): " + file.bookmarks.map { "\($0.displayTitle) thumb=\($0.thumbnail?.count ?? 0)" }.joined(separator: " | ")
            }
            let frame = windowController.window?.frame ?? .zero
            NSLog("OP-DUMP mode=%@ frame=%@ title=%@ playlist=%@ index=%d volume=%.0f speed=%.2f idle=%d\n%@",
                  String(describing: windowController.mode), NSStringFromRect(frame), windowController.window?.title ?? "",
                  playlist.items.map(\.lastPathComponent).joined(separator: ","), playlist.currentIndex ?? -1,
                  state.volume, state.speed, state.isIdle ? 1 : 0, files.joined(separator: "\n"))
        default:
            break
        }
        #endif
    }

    private func finishPlayback() {
        state.isIdle = true
        state.isPaused = true
        currentHasVideo = false
        windowController.exitFullscreen()
        windowController.setMode(.idle)
        render()
    }

    // MARK: Actions

    func perform(_ action: PlayerAction) {
        let s = settings.value
        let active = !state.isIdle

        switch action {
        case .playPause: togglePause()
        case .seekBackward1: seek(-s.seekStep(0))
        case .seekForward1: seek(s.seekStep(0))
        case .seekBackward2: seek(-s.seekStep(1))
        case .seekForward2: seek(s.seekStep(1))
        case .seekBackward3: seek(-s.seekStep(2))
        case .seekForward3: seek(s.seekStep(2))
        case .seekBackward4: seek(-s.seekStep(3))
        case .seekForward4: seek(s.seekStep(3))
        case .previousFrame: if active { mpv.commandString("frame-back-step") }
        case .nextFrame: if active { mpv.commandString("frame-step") }
        case .jumpToStart: if active { mpv.commandString("seek 0 absolute") }
        case .jumpToTime: if active { promptJumpToTime() }

        case .speedDown: changeSpeed(by: -s.speedStep)
        case .speedUp: changeSpeed(by: s.speedStep)
        case .speedReset: resetSpeed()

        case .volumeUp: setVolume(state.volume + s.volumeStep, showOSD: true)
        case .volumeDown: setVolume(state.volume - s.volumeStep, showOSD: true)
        case .mute:
            mpv.setFlag("mute", !state.isMuted)
            mpv.showText(state.isMuted ? "Unmuted" : "Muted")

        case .previousFile: playRelative(-1)
        case .nextFile: playRelative(1)

        case .addBookmark: addBookmark()
        case .showBookmarks: showBookmarkMenu()

        case .toggleFullscreen: windowController.toggleFullscreen()
        case .exitFullscreen: windowController.exitFullscreen()

        case .toggleSubtitles: if active { mpv.commandString("cycle sub-visibility") }
        case .cycleSubtitle: if active { mpv.commandString("cycle sub") }
        case .loadSubtitle: if active { promptLoadSubtitle() }
        case .subtitleDelayDown: if active { mpv.commandString("add sub-delay -0.5") }
        case .subtitleDelayUp: if active { mpv.commandString("add sub-delay 0.5") }
        case .subtitleDelayReset: if active { mpv.commandString("set sub-delay 0") }
        case .subtitleSizeUp: if active { mpv.commandString("add sub-scale 0.1") }
        case .subtitleSizeDown: if active { mpv.commandString("add sub-scale -0.1") }

        case .cycleAudio: if active { mpv.commandString("cycle audio") }
        case .audioDelayDown: if active { mpv.commandString("add audio-delay -0.05") }
        case .audioDelayUp: if active { mpv.commandString("add audio-delay 0.05") }
        case .audioDelayReset: if active { mpv.commandString("set audio-delay 0") }

        case .windowSizeHalf: windowController.scaleWindow(0.5)
        case .windowSizeNormal: windowController.scaleWindow(1)
        case .windowSizeOneAndHalf: windowController.scaleWindow(1.5)
        case .windowSizeDouble: windowController.scaleWindow(2)
        case .stayOnTop:
            let onTop = windowController.toggleStayOnTop()
            mpv.showText(onTop ? "Stay on Top: On" : "Stay on Top: Off")
        case .showInfo: if active { showInfo() }

        case .openFile: promptOpen(directories: false)
        case .openFolder: promptOpen(directories: true)
        case .closePlayback: closePlayback()
        case .preferences: onShowSettings?()
        case .playlist: onTogglePlaylist?()
        case .saveFrame: if active { saveFrame() }
        }
    }

    private func togglePause() {
        if state.isIdle {
            if let index = playlist.currentIndex ?? (playlist.items.isEmpty ? nil : 0) { play(index: index) }
            return
        }
        mpv.setFlag("pause", !state.isPaused)
    }

    private func seek(_ seconds: Double) {
        guard !state.isIdle else { return }
        mpv.commandString("seek \(seconds) relative")
    }

    private func changeSpeed(by delta: Double) {
        guard !state.isIdle else { return }
        let speed = min(4, max(0.1, ((state.speed + delta) * 100).rounded() / 100))
        mpv.setDouble("speed", speed)
        mpv.showText("Speed: \(ControlBar.speedText(speed))")
    }

    /// PotPlayer's "Default/Last used": toggles between normal speed and the last other speed.
    private func resetSpeed() {
        guard !state.isIdle else { return }
        if abs(state.speed - 1) > 0.001 {
            lastSpeed = state.speed
            mpv.setDouble("speed", 1)
            mpv.showText("Speed: 1×")
        } else if abs(lastSpeed - 1) > 0.001 {
            mpv.setDouble("speed", lastSpeed)
            mpv.showText("Speed: \(ControlBar.speedText(lastSpeed))")
        }
    }

    private func setVolume(_ volume: Double, showOSD: Bool) {
        let value = min(100, max(0, volume.rounded()))
        mpv.setDouble("volume", value)
        if state.isMuted { mpv.setFlag("mute", false) }
        state.volume = value
        settings.update { $0.volume = value }
        if showOSD { mpv.showText("Volume: \(Int(value))%") }
        render()
    }

    private func handleScroll(_ event: NSEvent) {
        guard settings.value.mouseWheelVolume, event.momentumPhase.isEmpty else { return }
        var delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 20
        if event.isDirectionInvertedFromDevice { delta = -delta }
        scrollAccumulator += delta
        let threshold: CGFloat = 20
        while scrollAccumulator >= threshold {
            scrollAccumulator -= threshold
            perform(.volumeUp)
        }
        while scrollAccumulator <= -threshold {
            scrollAccumulator += threshold
            perform(.volumeDown)
        }
        if event.phase == .ended || event.phase == .cancelled { scrollAccumulator = 0 }
    }

    private func showInfo() {
        let template = #"${filename}\n${?video-codec:Video: ${video-codec}  ${width}x${height}  ${estimated-vf-fps} fps\n}${?audio-codec-name:Audio: ${audio-codec-name}  ${audio-params/samplerate} Hz  ${audio-params/channel-count} ch\n}Hardware decoding: ${hwdec-current}\nSpeed: ${speed}   Volume: ${volume}%"#
        mpv.commandString("show-text \"\(template)\" 5000")
    }

    private func saveFrame() {
        guard let url = currentURL else { return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let stamp = TimeFormat.long(state.position).replacingOccurrences(of: ":", with: "-")
        let target = desktop.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(stamp).jpg")
        let ok = mpv.command(["screenshot-to-file", target.path, "video"]) >= 0
        mpv.showText(ok ? "Frame saved to Desktop" : "Couldn't save the frame")
    }

    // MARK: Bookmarks

    private func addBookmark() {
        guard let url = currentURL, !state.isIdle else { return }
        let position = mpv.getDouble("time-pos") ?? state.position
        do {
            let (bookmark, warning) = try bookmarks.add(url: url, seconds: position, thumbnail: nil)
            if currentHasVideo { bookmarks.generateThumbnail(for: bookmark) }
            mpv.showText("Bookmark added: \(bookmark.displayTitle)" + (warning.map { "\n\($0)" } ?? ""), durationMs: 2000)
        } catch {
            mpv.showText("Couldn't add bookmark: \(error.localizedDescription)")
        }
    }

    func showBookmarkMenu() {
        guard let window = windowController.window, let view = window.contentView else { return }
        let menu = makeBookmarkMenu()
        let mouse = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let point = view.bounds.contains(mouse) ? mouse : NSPoint(x: view.bounds.midX - 150, y: view.bounds.midY + 120)
        activeMenu = menu
        menu.popUp(positioning: nil, at: point, in: view)
        activeMenu = nil
    }

    private func makeBookmarkMenu() -> NSMenu {
        let handlers = BookmarkMenuBuilder.Handlers(
            jump: { [weak self] bookmark in self?.jump(to: bookmark) },
            rename: { [weak self] bookmark in self?.promptRename(bookmark) },
            delete: { [weak self] bookmark in
                guard let self else { return }
                let warning = self.bookmarks.delete(bookmark)
                self.mpv.showText("Bookmark deleted" + (warning.map { "\n\($0)" } ?? ""))
            },
            deleteAll: { [weak self] file in self?.confirmDeleteAll(file) },
            addHere: currentURL == nil ? nil : { [weak self] in self?.addBookmark() },
            manage: { [weak self] in self?.onShowBookmarkManager?() }
        )
        let builder = BookmarkMenuBuilder(handlers: handlers)
        menuBuilder = builder
        return builder.makeMenu(files: bookmarks.bookmarkedFiles(), currentPath: currentURL.map(BookmarkService.key),
                                keyMap: settings.value.keyMap)
    }

    func jump(to bookmark: Bookmark) {
        if let url = currentURL, BookmarkService.key(for: url) == bookmark.path, !state.isIdle {
            mpv.command(["seek", String(bookmark.seconds), "absolute+exact"])
            mpv.showText(bookmark.displayTitle)
            return
        }
        guard FileManager.default.fileExists(atPath: bookmark.path) else {
            return showError("“\(URL(fileURLWithPath: bookmark.path).lastPathComponent)” was not found.\nIs its drive connected?\n\n\(bookmark.path)")
        }
        open([URL(fileURLWithPath: bookmark.path)], startAt: bookmark.seconds)
    }

    func promptRename(_ bookmark: Bookmark) {
        let field = NSTextField(string: bookmark.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = "Rename Bookmark"
        alert.informativeText = "\(URL(fileURLWithPath: bookmark.path).lastPathComponent) at \(TimeFormat.long(bookmark.seconds))"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        runSheet(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if let warning = self.bookmarks.rename(bookmark, to: field.stringValue) { self.mpv.showText(warning) }
        }
    }

    func confirmDeleteAll(_ file: BookmarkedFile) {
        let alert = NSAlert()
        alert.messageText = "Delete all \(file.bookmarks.count) bookmarks of “\(file.fileName)”?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        runSheet(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if let warning = self.bookmarks.deleteAll(for: file.path) { self.mpv.showText(warning) }
        }
    }

    private func refreshBookmarkMarkers() {
        state.bookmarkPositions = currentURL.map { bookmarks.bookmarks(for: $0).map(\.seconds) } ?? []
        render()
    }

    // MARK: Dialogs

    private func promptJumpToTime() {
        let field = NSTextField(string: TimeFormat.long(state.position))
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        let alert = NSAlert()
        alert.messageText = "Jump to Time"
        alert.informativeText = "Enter hh:mm:ss, mm:ss or seconds."
        alert.accessoryView = field
        alert.addButton(withTitle: "Jump")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        runSheet(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let time = TimeFormat.parse(field.stringValue) else { return NSSound.beep() }
            self.mpv.command(["seek", String(time), "absolute+exact"])
        }
    }

    private func promptOpen(directories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = !directories
        panel.message = directories ? "Choose a folder to play" : "Choose files or a folder to play"
        if let window = windowController.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK { self?.open(panel.urls) }
            }
        }
    }

    private func promptLoadSubtitle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaTypes.subtitles.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = currentURL?.deletingLastPathComponent()
        if let window = windowController.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url { self?.loadSubtitle(url) }
            }
        }
    }

    private func loadSubtitle(_ url: URL) {
        mpv.command(["sub-add", url.path, "select"])
        mpv.showText("Subtitle: \(url.lastPathComponent)")
    }

    private func runSheet(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = windowController.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        runSheet(alert) { _ in }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ action: PlayerAction, enabled: Bool = true) {
            let item = NSMenuItem(title: action.title(seekSteps: settings.value.seekSteps), action: #selector(contextAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.isEnabled = enabled
            MenuShortcuts.show(action, on: item, keyMap: settings.value.keyMap)
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        add(.openFile)
        add(.openFolder)
        menu.addItem(.separator())
        add(.playPause, enabled: !state.isIdle)
        add(.addBookmark, enabled: !state.isIdle)
        add(.showBookmarks)
        add(.playlist)
        menu.addItem(.separator())
        add(.loadSubtitle, enabled: !state.isIdle)
        add(.cycleSubtitle, enabled: !state.isIdle)
        add(.cycleAudio, enabled: !state.isIdle)
        menu.addItem(.separator())
        add(.toggleFullscreen, enabled: currentHasVideo)
        add(.stayOnTop)
        add(.preferences)
        return menu
    }

    @objc private func contextAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = PlayerAction(rawValue: raw) else { return }
        perform(action)
    }

    // MARK: State

    private func saveResumePosition() {
        lastResumeSave = Date()
        guard settings.value.resumePlayback, let url = currentURL, !state.isIdle else { return }
        let key = BookmarkService.key(for: url)
        let position = state.position, duration = state.duration
        if duration > 0 && (position < 5 || position > duration - 10) {
            bookmarks.store.clearResumePosition(path: key)
        } else if position >= 5 {
            bookmarks.store.saveResumePosition(path: key, position: position, duration: duration > 0 ? duration : nil)
        }
    }

    /// Coalesces UI updates to once per run loop pass.
    private func render() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            let index = self.playlist.currentIndex ?? -1
            self.state.hasPrevious = index > 0
            self.state.hasNext = index >= 0 && index + 1 < self.playlist.items.count
            self.state.hasVideo = self.currentHasVideo
            self.lastRenderedPosition = self.state.position
            self.windowController.controlBar.update(state: self.state)
        }
    }

    func shutdown() {
        saveResumePosition()
        settings.saveNow()
        mpv.command(["stop"])
        windowController.videoView.videoLayer.destroyRenderContext()
        mpv.destroy()
    }
}

extension Notification.Name {
    static let bookmarksDidChange = Notification.Name("OpenPlayerBookmarksDidChange")
}

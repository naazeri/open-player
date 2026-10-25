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
    let mpv: MPVPlayer
    let bookmarks: BookmarkService
    let playlist = PlaylistModel()
    let state = PlaybackState()
    private(set) var windowController: PlayerWindowController!
    private var keyHandler: KeyInputHandler!

    var onShowSettings: (() -> Void)?
    var onTogglePlaylist: (() -> Void)?
    var onShowBookmarkManager: (() -> Void)?
    /// The player window was closed while the app keeps running.
    var onWindowClosed: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var appliedSettings: AppSettings?
    private var menuBuilder: BookmarkMenuBuilder?
    private var activeMenu: NSMenu?
    private var renderScheduled = false
    private var lastRenderedPosition = -1.0
    private var pendingResize = false
    private var pendingStartMessage: String?
    private var pendingRecentDocument: URL?
    /// Fires when a file hasn't opened after a few seconds (see `showOpeningHint`).
    private var openingWatchdog: Timer?
    private var lastResumeSave = Date.distantPast
    private var lastSpeed = 1.0
    /// The speed to return to when the 2× hold on the video ends.
    private var speedBeforeHold: Double?
    private let seekPreviewer = SeekPreviewer()
    /// The time the seek bar preview shows, while the mouse is over the bar.
    private var previewTime: Double?
    private var previewRestTimer: Timer?
    private var scrollAccumulator: CGFloat = 0
    private var currentHasVideo = false
    /// Folder scans run in the background; a newer playlist change makes older results stale.
    private var scanGeneration = 0
    private var pendingScan: (generation: Int, url: URL, scope: PlaylistScope)?
    /// Next/previous file or the end of a file while the folder scan is still running.
    private var afterScan: (() -> Void)?
    /// mpv reports the end of a file with `eof-reached` (keep-open); handled once per file.
    private var endHandled = false
    private var atEnd = false
    private var upNextTimer: Timer?
    private var upNextIndex: Int?
    /// mpv events that arrived before the window existed (the first file starts loading earlier).
    private var eventsBeforeWindow: [() -> Void] = []

    private var currentURL: URL? { playlist.currentURL }

    /// `initialURLs` are the files the app was launched with. A single file starts loading before
    /// the window is built, so mpv opens it while the interface is being set up.
    init(settings: SettingsStore, library: LibraryStore, initialURLs: [URL] = []) {
        // mpv's render context must exist before a file starts loading, or the video can't start.
        let player = MPVPlayer()
        let videoView = VideoView(player: player)
        self.settings = settings
        mpv = player
        bookmarks = BookmarkService(store: library, settings: settings)
        super.init()

        mpv.delegate = self
        mpv.setDouble("volume", settings.value.volume)
        state.volume = settings.value.volume
        keyHandler = KeyInputHandler { [weak self] action in self?.perform(action) }
        keyHandler.accepts = { [weak self] event in
            guard let window = self?.windowController?.window else { return false }
            return event.window === window && !(window.firstResponder is NSText)
        }
        apply(settings.value) // hardware decoding, subtitle options… before the first file

        let firstFile = Self.singleFile(initialURLs)
        if let firstFile {
            scanGeneration += 1
            playlist.items = [firstFile]
            playlist.currentIndex = 0
            beginLoad(firstFile, startAt: nil)
        }

        windowController = PlayerWindowController(videoView: videoView)
        keyHandler.start()
        wireUpWindow()
        bookmarks.onChange = { [weak self] in
            self?.refreshBookmarkMarkers()
            NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
        }
        settings.$value.sink { [weak self] value in self?.apply(value) }.store(in: &cancellables)

        if let firstFile {
            finishLoad(firstFile)
            scanFolder(around: firstFile)
            noteRecentDocument(firstFile)
        } else if !initialURLs.isEmpty {
            open(initialURLs)
        }
        let early = eventsBeforeWindow
        eventsBeforeWindow = []
        early.forEach { $0() }
        render()
    }

    /// Runs `work` now, or once the window exists if an mpv event arrives during setup.
    private func whenWindowReady(_ work: @escaping () -> Void) {
        if windowController == nil {
            eventsBeforeWindow.append(work)
        } else {
            work()
        }
    }

    /// The one media file in `urls`, if that's all there is (the usual "open this file" case).
    private static func singleFile(_ urls: [URL]) -> URL? {
        guard urls.count == 1, let url = urls.first, !MediaTypes.isSubtitle(url) else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return nil }
        return url
    }

    func showWindow() {
        windowController.present()
    }

    private func wireUpWindow() {
        let controlBar = windowController.controlBar
        controlBar.onAction = { [weak self] action in self?.perform(action) }
        controlBar.onVolumeChange = { [weak self] volume in self?.setVolume(volume, showOSD: false) }
        controlBar.onSpeedCycle = { [weak self] in
            guard let self else { return }
            self.setSpeed(SpeedSteps.cycle(from: self.state.speed))
        }
        controlBar.onSpeedReset = { [weak self] in
            guard let self, abs(self.state.speed - 1) > 0.001 else { return }
            self.lastSpeed = self.state.speed
            self.setSpeed(1)
        }
        controlBar.seekBar.onHover = { [weak self] time, x in self?.hoverSeekBar(time: time, x: x) }
        controlBar.seekBar.onSeek = { [weak self] time, final in
            self?.mpv.command(["seek", String(time), final ? "absolute+exact" : "absolute+keyframes"])
        }

        let video = windowController.videoView
        video.onClick = { [weak self] in
            guard let self, !self.state.isIdle else { return }
            // Shows the state the click leads to (like YouTube); a click at the end replays.
            let willPlay = self.isPaused || self.atEnd
            self.togglePause()
            self.windowController.flashPlayPause(playing: willPlay)
        }
        video.onDoubleClick = { [weak self] in
            self?.windowController.cancelPlayPauseFlash()
            self?.windowController.toggleFullscreen()
        }
        video.onScroll = { [weak self] event in self?.handleScroll(event) }
        video.onHoldStart = { [weak self] in
            guard let self, !self.state.isIdle, !self.isPaused, !self.atEnd else { return false }
            self.speedBeforeHold = self.state.speed
            self.mpv.setDouble("speed", 2)
            self.windowController.showFastForward(true)
            return true
        }
        video.onHoldEnd = { [weak self] in
            guard let self, let speed = self.speedBeforeHold else { return }
            self.speedBeforeHold = nil
            self.mpv.setDouble("speed", speed)
            self.windowController.showFastForward(false)
        }

        windowController.onUpNextCancel = { [weak self] in self?.cancelUpNext() }
        windowController.onUpNextPlayNow = { [weak self] in self?.playUpNext() }
        windowController.onDropURLs = { [weak self] urls in self?.open(urls) }
        windowController.onWillClose = { [weak self] in self?.windowDidClose() }
        windowController.keepsRunningOnClose = { [weak self] in self?.settings.value.keepRunningAfterClose ?? false }
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
                // Play right away; the rest of the folder joins the playlist when the scan finishes.
                setPlaylist([url], play: 0, startAt: startAt)
                scanFolder(around: url)
            }
            noteRecentDocument(url)
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
        scanGeneration += 1
        pendingScan = nil
        afterScan = nil
        playlist.items = items
        play(index: index, startAt: startAt)
    }

    func play(index: Int, startAt: Double? = nil) {
        guard playlist.items.indices.contains(index) else { return }
        cancelUpNext()
        saveResumePosition()
        let url = playlist.items[index]
        playlist.currentIndex = index
        closeSeekPreview()
        beginLoad(url, startAt: startAt)
        finishLoad(url)
    }

    /// Hands the file to mpv. Doesn't touch the window, so it can run before the window exists.
    private func beginLoad(_ url: URL, startAt: Double?) {
        // Queued before `loadfile`, so it runs before FILE_LOADED (which lists bookmarks for thumbnails).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentURL == url else { return }
            self.bookmarks.syncFromPBF(for: url)
            self.refreshBookmarkMarkers()
        }

        var start = startAt
        pendingStartMessage = nil
        if start == nil, settings.value.resumePlayback,
           let resume = bookmarks.store.resumePosition(for: BookmarkService.key(for: url)), resume > 5 {
            start = resume
            pendingStartMessage = "Resumed at \(TimeFormat.long(resume))  (Backspace: start over)"
        }

        openingWatchdog?.invalidate()
        openingWatchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, self.currentURL == url, !self.state.isIdle else { return }
            self.windowController?.showOpeningHint(fileName: url.lastPathComponent)
        }
        var command = ["loadfile", url.path, "replace"]
        if let start { command += ["-1", "start=\(start)"] }
        Signpost.event("loadfile")
        mpv.command(command)
        mpv.setFlag("pause", false)

        pendingResize = false
        endHandled = false
        atEnd = false
        state.isIdle = false
        state.position = start ?? 0
        state.duration = 0
    }

    /// Window side of starting a file: title, markers, and bringing back a closed window.
    private func finishLoad(_ url: URL) {
        windowController.setTitle(for: url)
        windowController.showLoading()
        refreshBookmarkMarkers()
        if windowController.isClosed { showWindow() }
        render()
    }

    /// Added to Open Recent once it has actually opened: macOS reads the file to make the
    /// entry, and while it waits for folder permission, quitting waited for that entry too.
    private func noteRecentDocument(_ url: URL) {
        pendingRecentDocument = url
    }

    /// Fills the playlist with the rest of `url`'s folder without delaying playback.
    private func scanFolder(around url: URL) {
        scanGeneration += 1
        afterScan = nil
        let generation = scanGeneration
        let scope = settings.value.playlistScope
        pendingScan = (generation, url, scope)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = FolderScanner.playlist(for: url, scope: scope)
            DispatchQueue.main.async { self?.applyScan(items, generation: generation, url: url) }
        }
    }

    private func applyScan(_ items: [URL], generation: Int, url: URL) {
        guard generation == scanGeneration, pendingScan?.generation == generation, currentURL == url else { return }
        pendingScan = nil
        let key = url.standardizedFileURL
        if let index = items.firstIndex(where: { $0.standardizedFileURL == key }) {
            var items = items
            items[index] = url // keep the exact URL that is playing (database key, title)
            playlist.items = items
            playlist.currentIndex = index
            render()
        }
        let action = afterScan
        afterScan = nil
        action?()
    }

    /// Runs `action` once the folder scan has filled the playlist (right away when it has). The
    /// main thread never scans itself: listing a folder can wait on a macOS permission answer.
    private func whenScanned(_ action: @escaping () -> Void) {
        if let scan = pendingScan, scan.generation == scanGeneration, currentURL == scan.url {
            afterScan = action
        } else {
            pendingScan = nil
            action()
        }
    }

    private func playRelative(_ offset: Int) {
        whenScanned { [weak self] in self?.playRelativeNow(offset) }
    }

    private func playRelativeNow(_ offset: Int) {
        guard let index = playlist.currentIndex else { return }
        let target = index + offset
        if playlist.items.indices.contains(target) {
            play(index: target)
        } else {
            mpv.showText(offset > 0 ? "This is the last file" : "This is the first file")
        }
    }

    private func stopOpeningWatchdog() {
        openingWatchdog?.invalidate()
        openingWatchdog = nil
        windowController?.hideOpeningHint()
    }

    func closePlayback() {
        stopOpeningWatchdog()
        cancelUpNext()
        closeSeekPreview()
        saveResumePosition()
        mpv.command(["stop"])
        scanGeneration += 1
        pendingScan = nil
        afterScan = nil
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

    private func windowDidClose() {
        guard settings.value.keepRunningAfterClose else { return NSApp.terminate(nil) }
        resetAfterWindowClosed()
    }

    /// The window was closed but the app keeps running: stop, and start fresh next time.
    private func resetAfterWindowClosed() {
        stopOpeningWatchdog()
        cancelUpNext()
        closeSeekPreview()
        saveResumePosition()
        mpv.command(["stop"])
        // Paused in mpv too, so the next file's "unpause" is a real change that updates the controls.
        mpv.setFlag("pause", true)
        scanGeneration += 1
        pendingScan = nil
        afterScan = nil
        playlist.items = []
        playlist.currentIndex = nil
        state.isIdle = true
        state.isPaused = true
        state.position = 0
        state.duration = 0
        currentHasVideo = false
        keyHandler.stopRepeating()
        windowController.setMode(.idle)
        refreshBookmarkMarkers()
        render()
        onWindowClosed?()
    }

    // MARK: MPVPlayerDelegate

    func mpvPropertyChanged(_ name: String, _ value: MPVValue) {
        whenWindowReady { [weak self] in self?.handlePropertyChange(name, value) }
    }

    private func handlePropertyChange(_ name: String, _ value: MPVValue) {
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
        case "eof-reached":
            atEnd = value.bool ?? false
            if !atEnd {
                endHandled = false // seeked back after the end: the next end counts again
            } else if !state.isIdle {
                handleEndOfFile()
            }
            return
        default:
            return
        }
        render()
    }

    func mpvFileLoaded() {
        whenWindowReady { [weak self] in self?.handleFileLoaded() }
    }

    private func handleFileLoaded() {
        Signpost.event("fileLoaded")
        stopOpeningWatchdog()
        if let url = pendingRecentDocument, url == currentURL {
            pendingRecentDocument = nil
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        let videoTrack = mpv.getInt("current-tracks/video/id")
        let isImage = mpv.getFlag("current-tracks/video/image") ?? false
        let isAlbumArt = mpv.getFlag("current-tracks/video/albumart") ?? false
        currentHasVideo = videoTrack != nil && !isImage && !isAlbumArt
        state.hasVideo = currentHasVideo
        // The new video's size arrives with the next VIDEO_RECONFIG; at this point mpv may still
        // report the previous file's dimensions.
        pendingResize = currentHasVideo
        if !currentHasVideo { windowController.setMode(.audio) }
        if currentHasVideo, let url = currentURL {
            // Later, so the extra decoder doesn't compete with the first frames for CPU and disk.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.currentURL == url else { return }
                self.bookmarks.generateMissingThumbnails(for: url)
            }
        }
        if let message = pendingStartMessage {
            pendingStartMessage = nil
            mpv.showText(message, durationMs: 2500)
        }
        render()
    }

    func mpvVideoReconfigured() {
        whenWindowReady { [weak self] in self?.handleVideoReconfigured() }
    }

    private func handleVideoReconfigured() {
        guard currentHasVideo, let width = mpv.getInt("dwidth"), let height = mpv.getInt("dheight"),
              width > 0, height > 0 else { return }
        Signpost.event("videoReconfig")
        VideoLayer.signalNextFrame()
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
        whenWindowReady { [weak self] in self?.handleEndFile(reason) }
    }

    private func handleEndFile(_ reason: MPVEndReason) {
        if case .redirect = reason {} else { stopOpeningWatchdog() }
        switch reason {
        case .eof:
            // With keep-open the end normally arrives as `eof-reached`; this is a fallback.
            handleEndOfFile()
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
        case "op-press":
            // Clicks the button with this title in the player window (e.g. "Cancel", "Play Now").
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == args.dropFirst().joined(separator: " ") { return button }
                return view.subviews.lazy.compactMap(find).first
            }
            if let content = windowController.window?.contentView, let button = find(content) { button.performClick(nil) }
        case "op-click-video":
            windowController.videoView.onClick?()
        case "op-close":
            windowController.window?.performClose(nil)
        case "op-dump":
            let files = bookmarks.bookmarkedFiles().map { file in
                "\(file.fileName): " + file.bookmarks.map { "\($0.displayTitle) thumb=\($0.thumbnail?.count ?? 0)" }.joined(separator: " | ")
            }
            let frame = windowController.window?.frame ?? .zero
            NSLog("OP-DUMP upNext=%d mode=%@ frame=%@ title=%@ playlist=%@ index=%d volume=%.0f speed=%.2f idle=%d\n%@",
                  windowController.isShowingUpNext ? 1 : 0,
                  String(describing: windowController.mode), NSStringFromRect(frame), windowController.window?.title ?? "",
                  playlist.items.map(\.lastPathComponent).joined(separator: ","), playlist.currentIndex ?? -1,
                  state.volume, state.speed, state.isIdle ? 1 : 0, files.joined(separator: "\n"))
        default:
            break
        }
        #endif
    }

    /// The current file played to its end: count down to the next file, play it, or stop.
    private func handleEndOfFile() {
        guard !endHandled else { return }
        endHandled = true
        if let url = currentURL { bookmarks.store.clearResumePosition(path: BookmarkService.key(for: url)) }
        whenScanned { [weak self] in self?.playNextAfterEnd() }
    }

    private func playNextAfterEnd() {
        guard let index = playlist.currentIndex, index + 1 < playlist.items.count else {
            mpv.command(["stop"])
            finishPlayback()
            return
        }
        if settings.value.nextFileCountdown {
            startUpNext(index + 1)
        } else {
            play(index: index + 1)
        }
    }

    // MARK: Up next

    private func startUpNext(_ index: Int) {
        cancelUpNext()
        upNextIndex = index
        var seconds = settings.value.nextFileCountdownSeconds
        windowController.showUpNext(fileName: playlist.items[index].lastPathComponent, seconds: seconds)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            seconds -= 1
            if seconds <= 0 {
                self.playUpNext()
            } else {
                self.windowController.updateUpNext(seconds: seconds)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        upNextTimer = timer
    }

    private func playUpNext() {
        guard let index = upNextIndex else { return }
        cancelUpNext()
        play(index: index)
    }

    /// Hides the countdown; the paused last frame stays.
    private func cancelUpNext() {
        upNextTimer?.invalidate()
        upNextTimer = nil
        upNextIndex = nil
        windowController?.hideUpNext()
    }

    private func finishPlayback() {
        closeSeekPreview()
        mpv.setFlag("pause", true) // see resetAfterWindowClosed
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

        case .speedDown: setSpeed(SpeedSteps.down(from: state.speed, step: s.speedStep))
        case .speedUp: setSpeed(SpeedSteps.up(from: state.speed, step: s.speedStep))
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
        case .exitFullscreen:
            if windowController.isShowingUpNext { cancelUpNext() } else { windowController.exitFullscreen() }

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

    // MARK: Seek bar preview

    /// Moving: a fast keyframe frame. Resting for a moment: the exact frame.
    private func hoverSeekBar(time: Double?, x: CGFloat) {
        previewRestTimer?.invalidate()
        guard let time, currentHasVideo, !state.isIdle, let url = currentURL else {
            previewTime = nil
            windowController.hideSeekPreview()
            return
        }
        previewTime = time
        windowController.showSeekPreview(time: TimeFormat.short(time, reference: state.duration), atSeekBarX: x,
                                         aspect: mpv.getDouble("video-params/aspect").map { CGFloat($0) })
        requestPreview(url: url, time: time, exact: false)
        previewRestTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.requestPreview(url: url, time: time, exact: true)
        }
    }

    private func requestPreview(url: URL, time: Double, exact: Bool) {
        seekPreviewer.request(url: url, time: time, exact: exact) { [weak self] image in
            guard let self, self.previewTime != nil, self.currentURL == url, let image else { return }
            self.windowController.setSeekPreviewImage(image)
        }
    }

    /// The preview's mpv keeps the file open, so it goes when the file does.
    private func closeSeekPreview() {
        previewRestTimer?.invalidate()
        previewTime = nil
        seekPreviewer.close()
        windowController?.setSeekPreviewImage(nil)
        windowController?.hideSeekPreview()
    }

    private func togglePause() {
        if state.isIdle {
            if let index = playlist.currentIndex ?? (playlist.items.isEmpty ? nil : 0) { play(index: index) }
            return
        }
        if atEnd {
            // mpv stays paused at the end of a file (keep-open): play it again from the start.
            cancelUpNext()
            endHandled = false
            mpv.commandString("seek 0 absolute")
            mpv.setFlag("pause", false)
            return
        }
        mpv.setFlag("pause", !isPaused)
    }

    /// mpv's own pause state. `state.isPaused` follows it through property events, but a toggle
    /// must never act on a stale copy: that left clicks and Space doing nothing.
    private var isPaused: Bool { mpv.getFlag("pause") ?? state.isPaused }

    private func seek(_ seconds: Double) {
        guard !state.isIdle else { return }
        mpv.commandString("seek \(seconds) relative")
    }

    /// Speed persists across files in mpv, so it can also be changed while idle.
    private func setSpeed(_ speed: Double) {
        mpv.setDouble("speed", speed)
        state.speed = speed
        render()
        mpv.showText("Speed: \(SpeedSteps.label(speed))")
    }

    /// PotPlayer's "Default/Last used": toggles between normal speed and the last other speed.
    private func resetSpeed() {
        if abs(state.speed - 1) > 0.001 {
            lastSpeed = state.speed
            setSpeed(1)
        } else if abs(lastSpeed - 1) > 0.001 {
            setSpeed(lastSpeed)
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
        activeMenu = menu
        if windowController.isClosed || !window.isVisible {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } else {
            let mouse = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let point = view.bounds.contains(mouse) ? mouse : NSPoint(x: view.bounds.midX - 150, y: view.bounds.midY + 120)
            menu.popUp(positioning: nil, at: point, in: view)
        }
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
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK { self?.open(panel.urls) }
        }
        // A sheet needs a visible window; after the window was closed, use a standalone panel.
        if let window = windowController.window, window.isVisible, !windowController.isClosed {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
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
            guard self.windowController != nil else { return }
            self.windowController.controlBar.update(state: self.state)
        }
    }

    func shutdown() {
        saveResumePosition()
        settings.saveNow()
        mpv.command(["stop"])
        // mpv only finishes once a pending file open returns, and an open that macOS holds for a
        // permission answer never does: quitting then hung. The process ends anyway, so give
        // mpv a second to shut down cleanly and then go.
        let done = DispatchSemaphore(value: 0)
        let layer = windowController.videoView.videoLayer
        DispatchQueue.global(qos: .userInitiated).async { [mpv] in
            layer.destroyRenderContext()
            mpv.destroy()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }
}

extension Notification.Name {
    static let bookmarksDidChange = Notification.Name("OpenPlayerBookmarksDidChange")
}

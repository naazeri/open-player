import AppKit
import OpenPlayerCore

/// What the window is showing, which decides its size and layout.
enum DisplayMode: Equatable {
    case idle
    case video(NSSize)
    case audio
}

/// The single player window: video, overlay control bar, auto-hide, sizing and fullscreen.
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    let videoView: VideoView
    let controlBar = ControlBar()
    private let contentContainer = PlayerContentView()
    private let placeholder = NSTextField(labelWithString: "")

    private(set) var mode: DisplayMode = .idle
    private var hideTimer: Timer?
    private var controlsVisible = true
    private var isPaused = true
    private var pendingVideoSize: NSSize?
    private var lastVideoSize: NSSize?

    var onDropURLs: (([URL]) -> Void)?
    var onWillClose: (() -> Void)?
    var onResignKey: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu)?

    var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }
    var isVideoVisible: Bool { if case .video = mode { return true } else { return false } }

    init(player: MPVPlayer) {
        videoView = VideoView(player: player)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Open Player"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.contentMinSize = NSSize(width: 360, height: 200)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("PlayerWindow")
        super.init(window: window)
        window.delegate = self
        buildLayout()
        if !window.setFrameUsingName("PlayerWindow") { window.center() }
        setMode(.idle)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildLayout() {
        guard let window else { return }
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = contentContainer

        placeholder.stringValue = "Drop a video or audio file here\nor press ⌘O"
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.maximumNumberOfLines = 0

        for view in [videoView, placeholder, controlBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor, constant: -ControlBar.height / 2),
            controlBar.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            controlBar.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            controlBar.heightAnchor.constraint(equalToConstant: ControlBar.height),
        ])

        contentContainer.onMouseActivity = { [weak self] in self?.pokeControls() }
        contentContainer.onMouseExit = { [weak self] in self?.hideControlsIfPlaying() }
        contentContainer.onDrop = { [weak self] urls in self?.onDropURLs?(urls) }
        contentContainer.isOverControls = { [weak self] point in
            guard let self else { return false }
            return self.controlBar.frame.contains(point)
        }
        videoView.onRightClick = { [weak self] event in
            guard let self, let menu = self.contextMenuProvider?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self.videoView)
        }
    }

    // MARK: Modes and sizing

    func setMode(_ newMode: DisplayMode, resize: Bool = true) {
        guard let window else { return }
        let previous = mode
        mode = newMode
        switch newMode {
        case .idle:
            placeholder.isHidden = false
            videoView.isHidden = false
            window.contentMinSize = NSSize(width: 360, height: 200)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            window.title = "Open Player"
            window.representedURL = nil
            if previous == .audio { setContentSize(NSSize(width: 960, height: 540)) }
            showControls()

        case .audio:
            placeholder.isHidden = true
            videoView.isHidden = true
            if isFullscreen { window.toggleFullScreen(nil) }
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            window.contentMinSize = NSSize(width: 460, height: ControlBar.height)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: ControlBar.height)
            let width = max(560, min(window.frame.width, 720))
            setContentSize(NSSize(width: width, height: ControlBar.height))
            showControls()

        case .video(let size):
            placeholder.isHidden = true
            videoView.isHidden = false
            window.contentMinSize = NSSize(width: 320, height: 180)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            lastVideoSize = size
            if resize {
                fit(videoSize: size, scale: 1)
            } else {
                window.contentAspectRatio = size
            }
            scheduleHide()
        }
    }

    /// Resizes the window to `videoSize × scale` points, shrinking it to fit the screen and keeping its center.
    func fit(videoSize: NSSize, scale: CGFloat) {
        guard let window, videoSize.width > 0, videoSize.height > 0 else { return }
        if isFullscreen {
            pendingVideoSize = videoSize
            return
        }
        window.contentAspectRatio = videoSize
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let chrome = window.frameRect(forContentRect: .zero).size
        let maxSize = NSSize(width: visible.width * 0.92 - chrome.width, height: visible.height * 0.92 - chrome.height)

        var size = NSSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let shrink = min(1, maxSize.width / size.width, maxSize.height / size.height)
        size = NSSize(width: size.width * shrink, height: size.height * shrink)
        let grow = max(1, 320 / size.width, 180 / size.height)
        size = NSSize(width: (size.width * grow).rounded(), height: (size.height * grow).rounded())

        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        var frame = NSRect(x: center.x - frameSize.width / 2, y: center.y - frameSize.height / 2,
                           width: frameSize.width, height: frameSize.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }

    func scaleWindow(_ scale: CGFloat) {
        guard case .video(let size) = mode else { return }
        fit(videoSize: size, scale: scale)
    }

    private func setContentSize(_ size: NSSize) {
        guard let window, !isFullscreen else { return }
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        var frame = window.frame
        frame.origin.y += frame.height - frameSize.height
        frame.size = frameSize
        window.setFrame(frame, display: true, animate: false)
    }

    func setTitle(for url: URL?) {
        guard let window else { return }
        window.title = url?.lastPathComponent ?? "Open Player"
        window.representedURL = url
    }

    func toggleFullscreen() {
        guard isVideoVisible || isFullscreen else { return }
        window?.toggleFullScreen(nil)
    }

    func exitFullscreen() {
        if isFullscreen { window?.toggleFullScreen(nil) }
    }

    func toggleStayOnTop() -> Bool {
        guard let window else { return false }
        window.level = window.level == .floating ? .normal : .floating
        return window.level == .floating
    }

    // MARK: Control bar visibility

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused { showControls() } else { scheduleHide() }
    }

    func pokeControls() {
        showControls()
        scheduleHide()
    }

    private func showControls() {
        hideTimer?.invalidate()
        guard !controlsVisible else { return }
        controlsVisible = true
        controlBar.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            controlBar.animator().alphaValue = 1
        }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        guard isVideoVisible, !isPaused else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.hideControlsIfPlaying()
        }
    }

    private func hideControlsIfPlaying() {
        guard isVideoVisible, !isPaused, controlsVisible, !controlBar.seekBar.isDragging else { return }
        if let window, contentContainer.isMouseOverControls(in: window) { return }
        controlsVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            controlBar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.controlsVisible else { return }
            self.controlBar.isHidden = true
        })
        if isFullscreen { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onWillClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        onResignKey?()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let size = pendingVideoSize {
            pendingVideoSize = nil
            fit(videoSize: size, scale: 1)
        } else if let size = lastVideoSize, isVideoVisible {
            window?.contentAspectRatio = size
        }
    }
}

/// Window content: reports mouse activity for auto-hide and accepts dropped files.
final class PlayerContentView: NSView {
    var onMouseActivity: (() -> Void)?
    var onMouseExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var isOverControls: ((NSPoint) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onMouseActivity?() }
    override func mouseEntered(with event: NSEvent) { onMouseActivity?() }
    override func mouseExited(with event: NSEvent) { onMouseExit?() }

    func isMouseOverControls(in window: NSWindow) -> Bool {
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) && (isOverControls?(point) ?? false)
    }

    // MARK: Drag and drop

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

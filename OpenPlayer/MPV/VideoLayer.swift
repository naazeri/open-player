import AppKit
import OpenGL.GL3

private func glProcAddress(_ context: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name,
          let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue),
          let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else { return nil }
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}

/// OpenGL layer that libmpv renders video frames into.
final class VideoLayer: CAOpenGLLayer {
    private let player: MPVPlayer
    private let pixelFormat: CGLPixelFormatObj
    private let context: CGLContextObj
    private var renderContext: OpaquePointer?
    private let renderQueue = DispatchQueue(label: "openplayer.mpv.render", qos: .userInteractive)
    #if DEBUG
    private var drawCount = 0
    #endif

    /// Set when a new video size is known; the next draw marks the "first frame" signpost.
    private static var firstFramePending = false

    static func signalNextFrame() {
        firstFramePending = true
    }

    init(player: MPVPlayer) {
        self.player = player
        (pixelFormat, context) = Self.makeContext()
        super.init()
        isAsynchronous = false
        isOpaque = true
        backgroundColor = NSColor.black.cgColor
        needsDisplayOnBoundsChange = true
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        createRenderContext()
    }

    /// Core Animation copies layers for presentation; the copy shares the GL objects.
    override init(layer: Any) {
        let other = layer as! VideoLayer
        player = other.player
        pixelFormat = other.pixelFormat
        context = other.context
        renderContext = nil
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static func makeContext() -> (CGLPixelFormatObj, CGLContextObj) {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFASupportsAutomaticGraphicsSwitching,
            CGLPixelFormatAttribute(0),
        ]
        var pixelFormat: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &pixelFormat, &count)
        guard let pixelFormat else { fatalError("No OpenGL pixel format") }

        var context: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &context)
        guard let context else { fatalError("No OpenGL context") }

        var swapInterval: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &swapInterval)
        CGLEnable(context, kCGLCEMPEngine)
        return (pixelFormat, context)
    }

    private func createRenderContext() {
        guard let handle = player.handle else { return }
        CGLLockContext(context)
        CGLSetCurrentContext(context)
        defer { CGLUnlockContext(context) }

        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }
        var initParams = mpv_opengl_init_params(get_proc_address: glProcAddress, get_proc_address_ctx: nil)
        withUnsafeMutablePointer(to: &initParams) { initPointer in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
                mpv_render_param(),
            ]
            let status = mpv_render_context_create(&renderContext, handle, &params)
            if status < 0 { NSLog("mpv_render_context_create failed: %s", mpv_error_string(status)) }
        }

        mpv_render_context_set_update_callback(renderContext, { context in
            guard let context else { return }
            let layer = Unmanaged<VideoLayer>.fromOpaque(context).takeUnretainedValue()
            layer.renderQueue.async { layer.display() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Must run before the mpv handle is destroyed.
    func destroyRenderContext() {
        guard let renderContext else { return }
        renderQueue.sync {}
        CGLLockContext(context)
        CGLSetCurrentContext(context)
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
        CGLUnlockContext(context)
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj { pixelFormat }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj { context }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }

        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        guard let renderContext, viewport[2] > 0, viewport[3] > 0 else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            glFlush()
            return
        }

        var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer), w: viewport[2], h: viewport[3], internal_format: 0)
        var flipY: Int32 = 1
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                    mpv_render_param(),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
        glFlush()
        if Self.firstFramePending {
            Self.firstFramePending = false
            Signpost.event("firstFrame")
        }
        #if DEBUG
        drawCount += 1
        if drawCount % 300 == 0 { NSLog("VideoLayer: %d frames drawn at %dx%d", drawCount, viewport[2], viewport[3]) }
        #endif
    }

    override func display() {
        super.display()
        CATransaction.flush()
    }
}

/// Hosts the video layer and turns mouse input into player gestures.
final class VideoView: NSView {
    let videoLayer: VideoLayer
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    /// Holding the right third of the video plays at 2× (like YouTube). `onHoldStart` returns
    /// false when it doesn't apply (e.g. paused); the release then counts as a normal click.
    var onHoldStart: (() -> Bool)?
    var onHoldEnd: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var draggedWindow = false
    /// The click that brings the window to the front only focuses it; it doesn't toggle pause.
    private var activatingClick: TimeInterval?
    /// A single click waits this long for a second click, so a double click (fullscreen) doesn't
    /// pause and resume the video first.
    private static let clickDelay = min(NSEvent.doubleClickInterval, 0.3)
    private var pendingClick: DispatchWorkItem?
    /// The first click of a slow double click already toggled pause; the second toggles it back.
    private var firstClickToggled = false
    private static let holdDelay: TimeInterval = 0.4
    private var pendingHold: DispatchWorkItem?
    private var isHolding = false

    init(player: MPVPlayer) {
        videoLayer = VideoLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func makeBackingLayer() -> CALayer { videoLayer }

    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Accepted so the window can be dragged by the video right away. AppKit only asks for the
    /// click that brings the window to the front (the app already counts as active by then), so
    /// that click is remembered and doesn't toggle pause.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event { activatingClick = event.timestamp }
        return true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        draggedWindow = false
        if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
        } else if convert(event.locationInWindow, from: nil).x >= bounds.width * 2 / 3 {
            let hold = DispatchWorkItem { [weak self] in
                guard let self, self.mouseDownEvent === event, !self.draggedWindow else { return }
                self.pendingHold = nil
                self.isHolding = self.onHoldStart?() ?? false
            }
            pendingHold = hold
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: hold)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, let window, !draggedWindow, !isHolding,
              window.styleMask.contains(.fullScreen) == false else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x,
                             event.locationInWindow.y - start.locationInWindow.y)
        if distance > 3 {
            draggedWindow = true
            pendingHold?.cancel()
            pendingHold = nil
            window.performDrag(with: start)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        pendingHold?.cancel()
        pendingHold = nil
        if isHolding {
            isHolding = false
            activatingClick = nil
            onHoldEnd?()
            return
        }
        guard !draggedWindow else { return }
        // A click toggles pause, a double click switches fullscreen.
        if event.clickCount == 1 {
            firstClickToggled = false
            let activating = activatingClick == mouseDownEvent?.timestamp
            activatingClick = nil
            guard !activating else { return }
            let click = DispatchWorkItem { [weak self] in
                self?.pendingClick = nil
                self?.firstClickToggled = true
                self?.onClick?()
            }
            pendingClick = click
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.clickDelay, execute: click)
        } else if event.clickCount == 2 {
            if firstClickToggled { onClick?() }
            firstClickToggled = false
            onDoubleClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}

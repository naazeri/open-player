import AppKit
import OpenPlayerCore

/// Seek bar with bookmark markers and a hover time label.
final class SeekBar: NSView {
    var duration: Double = 0 { didSet { if duration != oldValue { needsDisplay = true } } }
    var position: Double = 0 { didSet { if !isDragging && position != oldValue { needsDisplay = true } } }
    /// Bookmark positions in seconds.
    var markers: [Double] = [] { didSet { if markers != oldValue { needsDisplay = true } } }
    /// Called while dragging (`final == false`) and on release (`final == true`).
    var onSeek: ((Double, Bool) -> Void)?
    /// The time under the mouse and its x position (nil when the mouse leaves), for the preview.
    var onHover: ((Double?, CGFloat) -> Void)?
    /// Off while a preview picture shows the time instead.
    var showsHoverTime = true { didSet { if showsHoverTime != oldValue { needsDisplay = true } } }

    private(set) var isDragging = false
    private var dragPosition: Double = 0
    private var hoverX: CGFloat?
    private let trackHeight: CGFloat = 4

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }

    private var trackRect: NSRect {
        NSRect(x: 6, y: 8, width: max(0, bounds.width - 12), height: trackHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
        reportHover()
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        needsDisplay = true
        if !isDragging { onHover?(nil, 0) }
    }

    private func reportHover() {
        guard let hoverX, duration > 0 else { return }
        let track = trackRect
        onHover?(time(atX: hoverX), min(max(hoverX, track.minX), track.maxX))
    }

    override func mouseDown(with event: NSEvent) {
        guard duration > 0 else { return }
        isDragging = true
        update(with: event, final: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        hoverX = convert(event.locationInWindow, from: nil).x
        update(with: event, final: false)
        reportHover()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        update(with: event, final: true)
        isDragging = false
        position = dragPosition
        // Released outside the bar: no mouseExited follows.
        if !bounds.contains(convert(event.locationInWindow, from: nil)) {
            hoverX = nil
            onHover?(nil, 0)
        }
    }

    private func update(with event: NSEvent, final: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        dragPosition = time(atX: x)
        needsDisplay = true
        onSeek?(dragPosition, final)
    }

    private func time(atX x: CGFloat) -> Double {
        let track = trackRect
        guard track.width > 0 else { return 0 }
        let fraction = min(1, max(0, (x - track.minX) / track.width))
        return Double(fraction) * duration
    }

    private func x(forTime time: Double) -> CGFloat {
        let track = trackRect
        guard duration > 0 else { return track.minX }
        return track.minX + track.width * CGFloat(min(1, max(0, time / duration)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

        let current = isDragging ? dragPosition : position
        let progressX = x(forTime: current)
        var progress = track
        progress.size.width = progressX - track.minX
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: progress, xRadius: 2, yRadius: 2).fill()

        NSColor.systemYellow.setFill()
        for marker in markers where duration > 0 {
            let mx = x(forTime: marker)
            NSBezierPath(rect: NSRect(x: mx - 1, y: track.minY - 3, width: 2, height: track.height + 6)).fill()
        }

        if duration > 0 && (hoverX != nil || isDragging) {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: progressX - 6, y: track.midY - 6, width: 12, height: 12)).fill()
        }

        if let hoverX, duration > 0, showsHoverTime {
            let label = TimeFormat.short(time(atX: hoverX), reference: duration)
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ])
            let size = text.size()
            let labelX = min(max(0, hoverX - size.width / 2), bounds.width - size.width)
            text.draw(at: NSPoint(x: labelX, y: track.maxY + 6))
        }
    }
}

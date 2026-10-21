import AppKit

/// YouTube-style feedback for a click on the video: a dark circle with ▶︎ or ❚❚ that grows a little
/// and fades out. Plain layers only (no glass or blur), so nothing flickers over the video.
final class PlayPauseFlash: NSView {
    private static let diameter: CGFloat = 84
    private let circle = CALayer()
    private let icon = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        circle.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        circle.cornerRadius = Self.diameter / 2
        circle.opacity = 0
        icon.contentsGravity = .center
        circle.addSublayer(icon)
        layer?.addSublayer(circle)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never takes clicks
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        circle.position = CGPoint(x: bounds.midX, y: bounds.midY)
        icon.frame = circle.bounds
        CATransaction.commit()
    }

    /// `playing`: the video just started (▶︎) or was paused (❚❚).
    func flash(playing: Bool) {
        let scale = window?.backingScaleFactor ?? 2
        let configuration = NSImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let image = NSImage(systemSymbolName: playing ? "play.fill" : "pause.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        var rect = NSRect(origin: .zero, size: image?.size ?? .zero)
        icon.contents = image?.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        icon.contentsScale = scale

        circle.removeAllAnimations()
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.45, 1]
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.85
        grow.toValue = 1.3
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        group.duration = 0.6
        circle.opacity = 0 // final state once the animation ends
        circle.add(group, forKey: "flash")
    }

    /// The second click of a double click means "fullscreen", not play/pause.
    func cancel() {
        circle.removeAllAnimations()
    }
}

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

/// Shown at the top of the video while the right side is held for 2× playback (like YouTube).
final class FastForwardBadge: NSView {
    private let label = NSTextField(labelWithString: "2×")
    private let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 16
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        icon.image = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.contentTintColor = .white
        let stack = NSStackView(views: [label, icon])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never takes clicks

    func show(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = visible ? 1 : 0
        }
    }
}

/// The frame above the seek bar while hovering it (like YouTube), with the time below it.
/// Plain layers, positioned by its owner.
final class SeekPreviewView: NSView {
    /// The longer side of the picture.
    private static let side: CGFloat = 176
    private static let labelHeight: CGFloat = 20
    private let picture = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var aspect: CGFloat = 16 / 9

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        picture.backgroundColor = NSColor.black.cgColor
        picture.cornerRadius = 8
        picture.masksToBounds = true
        picture.borderWidth = 1.5
        picture.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        picture.contentsGravity = .resizeAspectFill
        layer?.addSublayer(picture)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.shadow = NSShadow()
        label.layer?.shadowColor = NSColor.black.cgColor
        label.layer?.shadowOpacity = 0.9
        label.layer?.shadowRadius = 3
        label.layer?.shadowOffset = .zero
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never takes clicks

    /// Size for the current video's proportions; portrait videos get a tall, narrow picture.
    var preferredSize: NSSize {
        let picture = aspect >= 1 ? NSSize(width: Self.side, height: (Self.side / aspect).rounded())
                                  : NSSize(width: (Self.side * aspect).rounded(), height: Self.side)
        return NSSize(width: max(picture.width, 64), height: picture.height + Self.labelHeight + 4)
    }

    func setAspect(_ value: CGFloat) {
        guard value.isFinite, value > 0.1 else { return }
        aspect = value
    }

    func show(time: String) {
        label.stringValue = time
        isHidden = false
    }

    /// nil clears the picture (new file); the previous frame otherwise stays until the next arrives.
    func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let size = preferredSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = NSRect(x: (bounds.width - (size.width)) / 2, y: Self.labelHeight + 4,
                               width: size.width, height: size.height - Self.labelHeight - 4)
        CATransaction.commit()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.labelHeight)
    }
}

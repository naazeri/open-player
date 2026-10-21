import AppKit

/// A rounded panel with Apple's Liquid Glass on macOS 26 and later, and a dark blur before that.
/// Add subviews to `content`.
final class GlassPanel: NSView {
    let content = NSView()

    /// `tint` darkens the glass so white controls stay readable over bright video.
    init(cornerRadius: CGFloat, tint: NSColor? = NSColor.black.withAlphaComponent(0.35)) {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        content.translatesAutoresizingMaskIntoConstraints = false

        let background: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            glass.contentView = content
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(content)
            background = effect
        }
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Glass-style button on macOS 26+, a normal rounded button before.
    static func button(_ title: String, target: AnyObject, action: Selector, prominent: Bool = false,
                       glass: Bool = true) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        if #available(macOS 26, *), glass {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }
        if prominent { button.bezelColor = .controlAccentColor }
        button.controlSize = .large
        button.refusesFirstResponder = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

/// A plain rounded card: solid colour, thin border, static shadow. Unlike glass or blur materials
/// it is never re-rendered by the system, so it can't flicker over video.
final class SolidCard: NSView {
    let content = NSView()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 0.94).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
}

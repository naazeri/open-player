import AppKit

/// Shown when a file has ended: the picture is blurred and a card says which file plays next,
/// with a countdown, Cancel and Play Now. The compact audio window gets a one-line version.
final class UpNextOverlay: NSView {
    var onCancel: (() -> Void)?
    var onPlayNow: (() -> Void)?

    // Deliberately no glass and no live blur: those are re-rendered by the system and flickered
    // over the paused video. A static dim layer and a solid card can't.
    private let backdrop = NSView()
    private let card = SolidCard(cornerRadius: 20)
    private let caption = NSTextField(labelWithString: "Up next")
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let compactLabel = NSTextField(labelWithString: "")
    /// Fixed-size stand-ins inside the glass; the changing labels are drawn above them, outside
    /// the glass. Liquid Glass re-renders its rim (wider than the card) whenever its content
    /// changes, which showed as a brief flash on every countdown tick.
    private let countdownSlot = NSView()
    private let compactSlot = NSView()
    private let fullStack = NSStackView()
    private let compactStack = NSStackView()
    private var cardWidth: NSLayoutConstraint!
    private var fullLayout: [NSLayoutConstraint] = []
    private var fullCardHeight: NSLayoutConstraint!
    private var compactLayout: [NSLayoutConstraint] = []
    private var fileName = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)

        // Darkens the last frame so the card reads easily.
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor

        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        caption.textColor = NSColor.white.withAlphaComponent(0.7)
        nameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.alignment = .center
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.preferredMaxLayoutWidth = 400
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        countdownLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        compactLabel.font = .systemFont(ofSize: 13, weight: .medium)
        compactLabel.textColor = .white
        compactLabel.lineBreakMode = .byTruncatingMiddle
        compactLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [
            GlassPanel.button("Cancel", target: self, action: #selector(cancelPressed), glass: false),
            GlassPanel.button("Play Now", target: self, action: #selector(playNowPressed), prominent: true, glass: false),
        ])
        buttons.spacing = 12
        fullStack.orientation = .vertical
        fullStack.alignment = .centerX
        fullStack.spacing = 8
        fullStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [caption, nameLabel, countdownSlot, buttons] as [NSView] { fullStack.addArrangedSubview(view) }
        fullStack.setCustomSpacing(16, after: countdownSlot)

        let compactCancel = GlassPanel.button("Cancel", target: self, action: #selector(cancelPressed), glass: false)
        let compactPlay = GlassPanel.button("Play Now", target: self, action: #selector(playNowPressed), prominent: true, glass: false)
        for button in [compactCancel, compactPlay] { button.controlSize = .regular }
        for view in [compactSlot, compactCancel, compactPlay] as [NSView] { compactStack.addArrangedSubview(view) }
        compactStack.orientation = .horizontal
        compactStack.spacing = 10
        compactStack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 10)

        for view in [backdrop, card, countdownLabel, compactLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        countdownSlot.translatesAutoresizingMaskIntoConstraints = false
        compactSlot.translatesAutoresizingMaskIntoConstraints = false
        compactSlot.setContentHuggingPriority(.defaultLow, for: .horizontal)
        compactSlot.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for stack in [fullStack, compactStack] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            card.content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: card.content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: card.content.trailingAnchor),
            ])
        }
        // The labels sit outside the glass, over their slots (needs the stacks in the hierarchy first).
        NSLayoutConstraint.activate([
            countdownSlot.widthAnchor.constraint(equalToConstant: 160),
            countdownSlot.heightAnchor.constraint(equalToConstant: 20),
            countdownLabel.centerXAnchor.constraint(equalTo: countdownSlot.centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: countdownSlot.centerYAnchor),
            countdownLabel.widthAnchor.constraint(equalTo: countdownSlot.widthAnchor),
            compactSlot.heightAnchor.constraint(equalToConstant: 20),
            compactLabel.leadingAnchor.constraint(equalTo: compactSlot.leadingAnchor),
            compactLabel.trailingAnchor.constraint(equalTo: compactSlot.trailingAnchor),
            compactLabel.centerYAnchor.constraint(equalTo: compactSlot.centerYAnchor),
        ])
        // The card's size is fixed when it appears: Liquid Glass animates every frame change, so a
        // card that re-measured itself on each countdown tick would briefly flash a bigger outline.
        // Below the window's own size priority (500), so the window never grows for the card.
        fullCardHeight = card.heightAnchor.constraint(equalToConstant: 190)
        fullCardHeight.priority = NSLayoutConstraint.Priority(450)
        fullLayout = [
            fullStack.centerYAnchor.constraint(equalTo: card.content.centerYAnchor),
            fullCardHeight,
        ]
        countdownLabel.alignment = .center
        compactLayout = [
            compactStack.centerYAnchor.constraint(equalTo: card.content.centerYAnchor),
            card.heightAnchor.constraint(equalToConstant: 44),
        ]
        cardWidth = card.widthAnchor.constraint(equalToConstant: 440)
        cardWidth.priority = NSLayoutConstraint.Priority(450)
        let fitsHeight = card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -8)
        fitsHeight.priority = .defaultHigh
        fitsHeight.isActive = true
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
            cardWidth,
        ])
        setCompact(false)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The audio window is only a control bar high: use the one-line layout there.
    func setCompact(_ compact: Bool) {
        fullStack.isHidden = compact
        compactStack.isHidden = !compact
        countdownLabel.isHidden = compact
        compactLabel.isHidden = !compact
        backdrop.isHidden = compact
        cardWidth.constant = compact ? 560 : 440
        NSLayoutConstraint.deactivate(compact ? fullLayout : compactLayout)
        NSLayoutConstraint.activate(compact ? compactLayout : fullLayout)
    }

    func show(fileName: String, seconds: Int) {
        self.fileName = fileName
        nameLabel.stringValue = fileName
        nameLabel.toolTip = fileName
        update(seconds: seconds)
        fullCardHeight.constant = ceil(fullStack.fittingSize.height)
    }

    func update(seconds: Int) {
        countdownLabel.stringValue = "Playing in \(seconds)"
        if !compactLabel.isHidden { compactLabel.stringValue = "“\(fileName)” plays in \(seconds)" }
    }

    @objc private func cancelPressed() { onCancel?() }
    @objc private func playNowPressed() { onPlayNow?() }
}

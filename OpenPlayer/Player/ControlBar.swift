import AppKit
import OpenPlayerCore

/// Floating bottom bar (Liquid Glass on macOS 26+): transport buttons, time, seek bar, speed,
/// volume and panel buttons.
final class ControlBar: NSView {
    static let height: CGFloat = 52
    /// Narrow windows (e.g. portrait video) get two rows: seek bar on top, buttons below.
    static let twoRowHeight: CGFloat = 86
    /// Below this bar width the single row has no room left for the seek bar.
    static let twoRowThreshold: CGFloat = 620
    /// Distance from the window edges.
    static let inset: CGFloat = 10
    /// Content height of the compact audio window, which is just the bar.
    static let windowHeight = height + 2 * inset
    /// The audio window stays wide enough for a single row.
    static let audioMinWidth = twoRowThreshold + 2 * inset

    let seekBar = SeekBar()
    var onAction: ((PlayerAction) -> Void)?
    var onVolumeChange: ((Double) -> Void)?
    /// Left click on the speed label (next 0.25 step) and right click (back to 1.0×).
    var onSpeedCycle: (() -> Void)?
    var onSpeedReset: (() -> Void)?

    private let playButton = ControlBar.button("play.fill", "Play/Pause")
    private let previousButton = ControlBar.button("backward.end.fill", "Previous File (PageUp)")
    private let nextButton = ControlBar.button("forward.end.fill", "Next File (PageDown)")
    private let muteButton = ControlBar.button("speaker.wave.2.fill", "Mute (M)")
    private let bookmarkButton = ControlBar.button("bookmark", "Bookmarks (H)")
    private let playlistButton = ControlBar.button("list.bullet", "Playlist (F6)")
    private let fullscreenButton = ControlBar.button("arrow.up.left.and.arrow.down.right", "Fullscreen (Enter)")
    private let timeLabel = ControlBar.label()
    private let durationLabel = ControlBar.label()
    private let speedLabel = SpeedLabel()
    private var playSymbol = "play.fill"
    private var volumeSymbol = "speaker.wave.2.fill"
    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let topRow = NSStackView()
    private let bottomRow = NSStackView()
    private let rowSpacer = NSView()
    private(set) var isTwoRow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        let panel = GlassPanel(cornerRadius: 18)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        playButton.target = self; playButton.action = #selector(playPressed)
        previousButton.target = self; previousButton.action = #selector(previousPressed)
        nextButton.target = self; nextButton.action = #selector(nextPressed)
        muteButton.target = self; muteButton.action = #selector(mutePressed)
        bookmarkButton.target = self; bookmarkButton.action = #selector(bookmarksPressed)
        playlistButton.target = self; playlistButton.action = #selector(playlistPressed)
        fullscreenButton.target = self; fullscreenButton.action = #selector(fullscreenPressed)

        volumeSlider.controlSize = .small
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.refusesFirstResponder = true
        volumeSlider.toolTip = "Volume (Up/Down)"
        volumeSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true

        speedLabel.onClick = { [weak self] in self?.onSpeedCycle?() }
        speedLabel.onRightClick = { [weak self] in self?.onSpeedReset?() }
        timeLabel.alignment = .right

        for row in [topRow, bottomRow] {
            row.orientation = .horizontal
            row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        }
        rowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let rows = NSStackView(views: [topRow, bottomRow])
        rows.orientation = .vertical
        rows.spacing = 2
        rows.translatesAutoresizingMaskIntoConstraints = false
        panel.content.addSubview(rows)
        arrange(twoRows: false)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: panel.content.leadingAnchor, constant: 4),
            rows.trailingAnchor.constraint(equalTo: panel.content.trailingAnchor, constant: -4),
            rows.centerYAnchor.constraint(equalTo: panel.content.centerYAnchor),
            topRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            seekBar.heightAnchor.constraint(equalToConstant: 34),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            // Wide enough for "1.75×", so the bar doesn't shift while cycling.
            speedLabel.widthAnchor.constraint(equalToConstant: 42),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: isTwoRow ? Self.twoRowHeight : Self.height)
    }

    override func layout() {
        super.layout()
        let twoRows = bounds.width < Self.twoRowThreshold
        if twoRows != isTwoRow { arrange(twoRows: twoRows) }
        // Very narrow: the mute button and the mouse wheel still control the volume.
        volumeSlider.isHidden = isTwoRow && bounds.width < 420
    }

    /// One row: everything side by side. Two rows: time + seek bar + duration on top, buttons below.
    private func arrange(twoRows: Bool) {
        isTwoRow = twoRows
        for row in [topRow, bottomRow] { row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() } }
        let buttons: [NSView] = [previousButton, playButton, nextButton]
        let tools: [NSView] = [speedLabel, muteButton, volumeSlider, bookmarkButton, playlistButton, fullscreenButton]
        if twoRows {
            [timeLabel, seekBar, durationLabel].forEach(topRow.addArrangedSubview)
            (buttons + [rowSpacer] + tools).forEach(bottomRow.addArrangedSubview)
        } else {
            (buttons + [timeLabel, seekBar, durationLabel] + tools).forEach(topRow.addArrangedSubview)
            topRow.setCustomSpacing(14, after: nextButton)
            topRow.setCustomSpacing(14, after: durationLabel)
        }
        bottomRow.isHidden = !twoRows
        invalidateIntrinsicContentSize()
    }

    func update(state: PlaybackState) {
        let play = state.isPaused || state.isIdle ? "play.fill" : "pause.fill"
        if play != playSymbol {
            playSymbol = play
            playButton.image = Self.symbol(play)
        }
        timeLabel.stringValue = state.isIdle ? "--:--" : TimeFormat.short(state.position, reference: state.duration)
        durationLabel.stringValue = state.isIdle ? "--:--" : TimeFormat.short(state.duration, reference: state.duration)
        seekBar.duration = state.duration
        seekBar.position = state.position
        seekBar.markers = state.bookmarkPositions
        seekBar.showsHoverTime = !state.hasVideo
        if !volumeSlider.isHighlighted { volumeSlider.doubleValue = state.volume }
        let volume: String
        if state.isMuted || state.volume == 0 { volume = "speaker.slash.fill" }
        else if state.volume < 34 { volume = "speaker.wave.1.fill" }
        else { volume = "speaker.wave.2.fill" }
        if volume != volumeSymbol {
            volumeSymbol = volume
            muteButton.image = Self.symbol(volume)
        }
        speedLabel.show(speed: state.speed)
        fullscreenButton.isHidden = !state.hasVideo
        previousButton.isEnabled = state.hasPrevious
        nextButton.isEnabled = state.hasNext
    }

    @objc private func playPressed() { onAction?(.playPause) }
    @objc private func previousPressed() { onAction?(.previousFile) }
    @objc private func nextPressed() { onAction?(.nextFile) }
    @objc private func mutePressed() { onAction?(.mute) }
    @objc private func bookmarksPressed() { onAction?(.showBookmarks) }
    @objc private func playlistPressed() { onAction?(.playlist) }
    @objc private func fullscreenPressed() { onAction?(.toggleFullscreen) }
    @objc private func volumeChanged() { onVolumeChange?(volumeSlider.doubleValue) }

    /// SF Symbols are loaded once and reused; `update(state:)` runs several times a second.
    private static var symbols: [String: NSImage] = [:]

    static func symbol(_ name: String) -> NSImage {
        if let image = symbols[name] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        symbols[name] = image
        return image
    }

    private static func button(_ symbol: String, _ tooltip: String) -> NSButton {
        let button = NSButton(image: Self.symbol(symbol), target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.refusesFirstResponder = true
        button.toolTip = tooltip
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private static func label() -> NSTextField {
        let label = NSTextField(labelWithString: "--:--")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }
}

/// The always-visible speed: click for the next 0.25× step (up to 2×, then 1×), right-click for 1×.
private final class SpeedLabel: NSTextField {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        toolTip = "Playback speed — click: +0.25× (up to 2×), right-click: 1×"
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        show(speed: 1)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(speed: Double) {
        let text = SpeedSteps.label(speed)
        if stringValue != text { stringValue = text }
        let normal = abs(speed - 1) < 0.001
        textColor = normal ? NSColor.white.withAlphaComponent(0.75) : .systemYellow
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
}

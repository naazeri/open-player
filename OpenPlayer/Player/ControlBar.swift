import AppKit
import OpenPlayerCore

/// Bottom bar: transport buttons, time, seek bar, speed, volume and panel buttons.
final class ControlBar: NSVisualEffectView {
    static let height: CGFloat = 52

    let seekBar = SeekBar()
    var onAction: ((PlayerAction) -> Void)?
    var onVolumeChange: ((Double) -> Void)?

    private let playButton = ControlBar.button("play.fill", "Play/Pause")
    private let previousButton = ControlBar.button("backward.end.fill", "Previous File (PageUp)")
    private let nextButton = ControlBar.button("forward.end.fill", "Next File (PageDown)")
    private let muteButton = ControlBar.button("speaker.wave.2.fill", "Mute (M)")
    private let bookmarkButton = ControlBar.button("bookmark", "Bookmarks (H)")
    private let playlistButton = ControlBar.button("list.bullet", "Playlist (F6)")
    private let fullscreenButton = ControlBar.button("arrow.up.left.and.arrow.down.right", "Fullscreen (Enter)")
    private let timeLabel = ControlBar.label()
    private let durationLabel = ControlBar.label()
    private let speedLabel = ControlBar.label()
    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)

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

        speedLabel.textColor = .systemYellow
        speedLabel.isHidden = true
        timeLabel.alignment = .right

        let stack = NSStackView(views: [
            previousButton, playButton, nextButton, timeLabel, seekBar, durationLabel, speedLabel,
            muteButton, volumeSlider, bookmarkButton, playlistButton, fullscreenButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.setCustomSpacing(14, after: nextButton)
        stack.setCustomSpacing(14, after: speedLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            seekBar.heightAnchor.constraint(equalToConstant: 34),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    func update(state: PlaybackState) {
        playButton.image = NSImage(systemSymbolName: state.isPaused || state.isIdle ? "play.fill" : "pause.fill",
                                   accessibilityDescription: "Play/Pause")
        timeLabel.stringValue = state.isIdle ? "--:--" : TimeFormat.short(state.position, reference: state.duration)
        durationLabel.stringValue = state.isIdle ? "--:--" : TimeFormat.short(state.duration, reference: state.duration)
        seekBar.duration = state.duration
        seekBar.position = state.position
        seekBar.markers = state.bookmarkPositions
        if !volumeSlider.isHighlighted { volumeSlider.doubleValue = state.volume }
        let volumeSymbol: String
        if state.isMuted || state.volume == 0 { volumeSymbol = "speaker.slash.fill" }
        else if state.volume < 34 { volumeSymbol = "speaker.wave.1.fill" }
        else { volumeSymbol = "speaker.wave.2.fill" }
        muteButton.image = NSImage(systemSymbolName: volumeSymbol, accessibilityDescription: "Mute")
        speedLabel.isHidden = abs(state.speed - 1) < 0.001
        speedLabel.stringValue = Self.speedText(state.speed)
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

    private static func button(_ symbol: String, _ tooltip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
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

    static func speedText(_ speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
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

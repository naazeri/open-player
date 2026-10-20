import AppKit
import OpenPlayerCore

/// Maps key presses in the player window to actions. Holding a repeatable key fires the action
/// on our own timer (configurable delay/interval) instead of the system key-repeat rate.
final class KeyInputHandler {
    var keyMap = KeyMap()
    var repeatDelay: TimeInterval = 0.3
    var repeatInterval: TimeInterval = 0.05
    /// Whether a key event belongs to the player (its window is the player window, no text editing).
    var accepts: (NSEvent) -> Bool = { _ in true }
    let perform: (PlayerAction) -> Void

    private var monitor: Any?
    private var heldKeyCode: UInt16?
    private var heldModifiers: KeyModifiers = []
    private var delayTimer: Timer?
    private var repeatTimer: Timer?

    init(perform: @escaping (PlayerAction) -> Void) {
        self.perform = perform
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stopRepeating() {
        delayTimer?.invalidate()
        repeatTimer?.invalidate()
        delayTimer = nil
        repeatTimer = nil
        heldKeyCode = nil
    }

    static func modifiers(of flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            guard accepts(event) else { return event }
            let combo = KeyCombo(event.keyCode, Self.modifiers(of: event.modifierFlags))
            guard let action = keyMap.action(for: combo) else { return event }
            // System auto-repeat is swallowed; our timer drives repetition.
            if event.isARepeat { return nil }
            stopRepeating()
            perform(action)
            if action.repeatsWhileHeld { startRepeating(action, keyCode: event.keyCode, modifiers: combo.modifiers) }
            return nil

        case .keyUp:
            if event.keyCode == heldKeyCode { stopRepeating() }
            return event

        case .flagsChanged:
            if heldKeyCode != nil && Self.modifiers(of: event.modifierFlags) != heldModifiers { stopRepeating() }
            return event

        default:
            return event
        }
    }

    #if DEBUG
    /// Feeds a synthetic key event through the normal path (automated checks only).
    func simulate(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, down: Bool, repeat isRepeat: Bool = false, window: NSWindow?) {
        guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0, context: nil,
                                           characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat,
                                           keyCode: keyCode) else { return }
        _ = handle(event)
    }
    #endif

    private func startRepeating(_ action: PlayerAction, keyCode: UInt16, modifiers: KeyModifiers) {
        heldKeyCode = keyCode
        heldModifiers = modifiers
        let delay = Timer(timeInterval: repeatDelay, repeats: false) { [weak self] _ in
            guard let self, self.heldKeyCode == keyCode else { return }
            let repeating = Timer(timeInterval: self.repeatInterval, repeats: true) { [weak self] _ in
                guard let self, self.heldKeyCode == keyCode else { return }
                self.perform(action)
            }
            self.repeatTimer = repeating
            RunLoop.main.add(repeating, forMode: .common)
            self.perform(action)
        }
        delayTimer = delay
        RunLoop.main.add(delay, forMode: .common)
    }
}

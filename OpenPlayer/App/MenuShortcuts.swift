import AppKit
import OpenPlayerCore

/// Shows the player's shortcuts in menus the native way (right-aligned, with ⌘⌥⇧⌃ glyphs).
///
/// The player's key handler owns these keys, so a menu must not fire them itself — otherwise
/// typing "p" in a text field could add a bookmark. `AppDelegate.validateMenuItem` blocks
/// key-equivalent matching for display-only items; items tagged `nativeTag` (⌘O, ⌘, …) still fire.
enum MenuShortcuts {
    static let nativeTag = 0x0B_EE

    /// The player's first shortcut for `action` (that a menu can draw) on `item`.
    static func show(_ action: PlayerAction, on item: NSMenuItem, keyMap: KeyMap) {
        guard let (key, mask) = keyMap.combos(for: action).lazy.compactMap(equivalent(for:)).first else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }

    static func equivalent(for combo: KeyCombo) -> (String, NSEvent.ModifierFlags)? {
        var mask: NSEvent.ModifierFlags = []
        if combo.modifiers.contains(.control) { mask.insert(.control) }
        if combo.modifiers.contains(.option) { mask.insert(.option) }
        if combo.modifiers.contains(.shift) { mask.insert(.shift) }
        if combo.modifiers.contains(.command) { mask.insert(.command) }

        // AppKit draws PageUp/PageDown like the arrow keys; use the classic Mac symbols instead.
        let pageSymbols: [UInt16: String] = [
            KeyCodes.pageUp: "\u{21DE}", KeyCodes.pageDown: "\u{21DF}",
            KeyCodes.home: "\u{2196}", KeyCodes.end: "\u{2198}",
        ]
        if let symbol = pageSymbols[combo.keyCode] { return (symbol, mask) }
        let functionKeys: [UInt16: Int] = [
            KeyCodes.left: NSLeftArrowFunctionKey, KeyCodes.right: NSRightArrowFunctionKey,
            KeyCodes.up: NSUpArrowFunctionKey, KeyCodes.down: NSDownArrowFunctionKey, 0x75: NSDeleteFunctionKey,
            KeyCodes.f1: NSF1FunctionKey, KeyCodes.f2: NSF2FunctionKey, KeyCodes.f3: NSF3FunctionKey,
            KeyCodes.f4: NSF4FunctionKey, KeyCodes.f5: NSF5FunctionKey, KeyCodes.f6: NSF6FunctionKey,
            0x62: NSF7FunctionKey, 0x64: NSF8FunctionKey, 0x65: NSF9FunctionKey, 0x6D: NSF10FunctionKey,
            0x67: NSF11FunctionKey, 0x6F: NSF12FunctionKey,
        ]
        if let function = functionKeys[combo.keyCode], let scalar = UnicodeScalar(function) {
            return (String(Character(scalar)), mask)
        }
        switch combo.keyCode {
        case KeyCodes.returnKey: return ("\r", mask)
        case KeyCodes.keypadEnter: return ("\u{3}", mask)
        case KeyCodes.backspace: return ("\u{8}", mask)
        case KeyCodes.escape: return ("\u{1b}", mask)
        case KeyCodes.tab: return ("\t", mask)
        case KeyCodes.space: return (" ", mask)
        case KeyCodes.slash where mask.contains(.shift):
            // AppKit draws nothing for ⇧/, so show the character it types.
            return ("?", mask)
        default:
            let name = KeyCodes.name(for: combo.keyCode)
            return name.count == 1 ? (name.lowercased(), mask) : nil
        }
    }

    /// True while AppKit is matching a key press against menu key equivalents.
    static var isMatchingKeyEquivalent: Bool { NSApp.currentEvent?.type == .keyDown }
}

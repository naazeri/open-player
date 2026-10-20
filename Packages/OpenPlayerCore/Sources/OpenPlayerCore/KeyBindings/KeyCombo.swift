import Foundation

/// Modifier keys, independent of AppKit so the core stays testable.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// A physical key (macOS virtual key code) plus modifiers.
/// Key codes are layout independent, so bindings keep working with a Persian keyboard layout.
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible, Codable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(_ keyCode: UInt16, _ modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Human readable, Windows style: "Ctrl+Alt+Left".
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        parts.append(KeyCodes.name(for: keyCode))
        return parts.joined(separator: "+")
    }

    /// Parses strings produced by `description`. Also accepts Option/Opt, Command/⌘, Control.
    public init?(string: String) {
        let tokens = string.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // "Ctrl++" style is not supported; the plus key is called "=" / "Equal".
        guard let keyToken = tokens.last, !keyToken.isEmpty else { return nil }
        var mods: KeyModifiers = []
        for token in tokens.dropLast() {
            switch token.lowercased() {
            case "ctrl", "control", "⌃": mods.insert(.control)
            case "alt", "option", "opt", "⌥": mods.insert(.option)
            case "shift", "⇧": mods.insert(.shift)
            case "cmd", "command", "⌘": mods.insert(.command)
            default: return nil
            }
        }
        guard let code = KeyCodes.code(for: keyToken) else { return nil }
        self.init(code, mods)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let combo = KeyCombo(string: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown key combo \(raw)")
        }
        self = combo
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// macOS virtual key codes (Carbon kVK_*), named the way PotPlayer names them.
public enum KeyCodes {
    public static let a: UInt16 = 0x00, s: UInt16 = 0x01, d: UInt16 = 0x02, f: UInt16 = 0x03
    public static let h: UInt16 = 0x04, g: UInt16 = 0x05, z: UInt16 = 0x06, x: UInt16 = 0x07
    public static let c: UInt16 = 0x08, v: UInt16 = 0x09, b: UInt16 = 0x0B, q: UInt16 = 0x0C
    public static let w: UInt16 = 0x0D, e: UInt16 = 0x0E, r: UInt16 = 0x0F, y: UInt16 = 0x10
    public static let t: UInt16 = 0x11, o: UInt16 = 0x1F, u: UInt16 = 0x20, i: UInt16 = 0x22
    public static let p: UInt16 = 0x23, l: UInt16 = 0x25, j: UInt16 = 0x26, k: UInt16 = 0x28
    public static let n: UInt16 = 0x2D, m: UInt16 = 0x2E
    public static let one: UInt16 = 0x12, two: UInt16 = 0x13, three: UInt16 = 0x14, four: UInt16 = 0x15
    public static let returnKey: UInt16 = 0x24, tab: UInt16 = 0x30, space: UInt16 = 0x31
    public static let backspace: UInt16 = 0x33, escape: UInt16 = 0x35
    public static let comma: UInt16 = 0x2B, period: UInt16 = 0x2F, slash: UInt16 = 0x2C
    public static let keypadEnter: UInt16 = 0x4C
    public static let f1: UInt16 = 0x7A, f2: UInt16 = 0x78, f3: UInt16 = 0x63, f4: UInt16 = 0x76
    public static let f5: UInt16 = 0x60, f6: UInt16 = 0x61
    public static let home: UInt16 = 0x73, end: UInt16 = 0x77, pageUp: UInt16 = 0x74, pageDown: UInt16 = 0x79
    public static let left: UInt16 = 0x7B, right: UInt16 = 0x7C, down: UInt16 = 0x7D, up: UInt16 = 0x7E

    private static let table: [(UInt16, String)] = [
        (0x00, "A"), (0x01, "S"), (0x02, "D"), (0x03, "F"), (0x04, "H"), (0x05, "G"), (0x06, "Z"),
        (0x07, "X"), (0x08, "C"), (0x09, "V"), (0x0B, "B"), (0x0C, "Q"), (0x0D, "W"), (0x0E, "E"),
        (0x0F, "R"), (0x10, "Y"), (0x11, "T"), (0x12, "1"), (0x13, "2"), (0x14, "3"), (0x15, "4"),
        (0x16, "6"), (0x17, "5"), (0x18, "="), (0x19, "9"), (0x1A, "7"), (0x1B, "-"), (0x1C, "8"),
        (0x1D, "0"), (0x1E, "]"), (0x1F, "O"), (0x20, "U"), (0x21, "["), (0x22, "I"), (0x23, "P"),
        (0x24, "Enter"), (0x25, "L"), (0x26, "J"), (0x27, "'"), (0x28, "K"), (0x29, ";"), (0x2A, "\\"),
        (0x2B, ","), (0x2C, "/"), (0x2D, "N"), (0x2E, "M"), (0x2F, "."), (0x30, "Tab"), (0x31, "Space"),
        (0x32, "`"), (0x33, "Backspace"), (0x35, "Esc"),
        (0x41, "NumpadDot"), (0x43, "NumpadMultiply"), (0x45, "NumpadPlus"), (0x47, "NumpadClear"),
        (0x4B, "NumpadDivide"), (0x4C, "NumpadEnter"), (0x4E, "NumpadMinus"), (0x51, "NumpadEqual"),
        (0x52, "Numpad0"), (0x53, "Numpad1"), (0x54, "Numpad2"), (0x55, "Numpad3"), (0x56, "Numpad4"),
        (0x57, "Numpad5"), (0x58, "Numpad6"), (0x59, "Numpad7"), (0x5B, "Numpad8"), (0x5C, "Numpad9"),
        (0x60, "F5"), (0x61, "F6"), (0x62, "F7"), (0x63, "F3"), (0x64, "F8"), (0x65, "F9"), (0x67, "F11"),
        (0x6D, "F10"), (0x6F, "F12"), (0x76, "F4"), (0x78, "F2"), (0x7A, "F1"),
        (0x73, "Home"), (0x74, "PageUp"), (0x75, "Del"), (0x77, "End"), (0x79, "PageDown"),
        (0x7B, "Left"), (0x7C, "Right"), (0x7D, "Down"), (0x7E, "Up"),
    ]

    private static let byCode: [UInt16: String] = Dictionary(uniqueKeysWithValues: table)
    private static let byName: [String: UInt16] = {
        var map = Dictionary(uniqueKeysWithValues: table.map { ($0.1.lowercased(), $0.0) })
        // Aliases.
        map["return"] = 0x24
        map["delete"] = 0x33
        map["escape"] = 0x35
        map["pgup"] = 0x74
        map["pgdn"] = 0x79
        map["pagedn"] = 0x79
        map["forwarddelete"] = 0x75
        map["equal"] = 0x18
        map["minus"] = 0x1B
        return map
    }()

    public static func name(for code: UInt16) -> String {
        byCode[code] ?? String(format: "Key%02X", code)
    }

    public static func code(for name: String) -> UInt16? {
        if let code = byName[name.lowercased()] { return code }
        if name.lowercased().hasPrefix("key"), let value = UInt16(name.dropFirst(3), radix: 16) { return value }
        return nil
    }
}

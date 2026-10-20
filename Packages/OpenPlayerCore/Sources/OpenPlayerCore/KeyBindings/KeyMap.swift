import Foundation

/// Resolves key combos to actions: PotPlayer defaults, with per-action user overrides on top.
public struct KeyMap: Equatable, Sendable {
    public private(set) var bindings: [PlayerAction: [KeyCombo]]
    private var lookup: [KeyCombo: PlayerAction] = [:]

    /// `overrides` maps an action raw value to its full list of combos (as strings).
    /// Unknown actions and unparsable combos are ignored so old or hand-edited settings never break loading.
    public init(overrides: [String: [String]] = [:]) {
        var result = DefaultKeyMap.bindings
        for (rawAction, combos) in overrides {
            guard let action = PlayerAction(rawValue: rawAction) else { continue }
            result[action] = combos.compactMap(KeyCombo.init(string:))
        }
        bindings = result
        rebuildLookup()
    }

    public func action(for combo: KeyCombo) -> PlayerAction? {
        lookup[combo]
    }

    public func combos(for action: PlayerAction) -> [KeyCombo] {
        bindings[action] ?? []
    }

    /// The action already using `combo`, other than `action`.
    public func conflict(for combo: KeyCombo, excluding action: PlayerAction) -> PlayerAction? {
        for candidate in PlayerAction.allCases where candidate != action {
            if bindings[candidate]?.contains(combo) == true { return candidate }
        }
        return nil
    }

    /// Overrides needed to reproduce this map (only actions that differ from the defaults).
    public var overrides: [String: [String]] {
        var result: [String: [String]] = [:]
        for action in PlayerAction.allCases {
            let current = bindings[action] ?? []
            if current != (DefaultKeyMap.bindings[action] ?? []) {
                result[action.rawValue] = current.map(\.description)
            }
        }
        return result
    }

    public mutating func set(_ combos: [KeyCombo], for action: PlayerAction) {
        bindings[action] = combos
        rebuildLookup()
    }

    private mutating func rebuildLookup() {
        lookup = [:]
        // Deterministic: the first action in declaration order wins a shared combo.
        for action in PlayerAction.allCases {
            for combo in bindings[action] ?? [] where lookup[combo] == nil {
                lookup[combo] = action
            }
        }
    }

    public static func == (lhs: KeyMap, rhs: KeyMap) -> Bool {
        lhs.bindings == rhs.bindings
    }
}

/// PotPlayer 1.7.22619 defaults (from its English.ini menu definitions), limited to the actions above.
public enum DefaultKeyMap {
    public static let bindings: [PlayerAction: [KeyCombo]] = {
        typealias K = KeyCodes
        let ctrl = KeyModifiers.control, alt = KeyModifiers.option, shift = KeyModifiers.shift, cmd = KeyModifiers.command
        return [
            .playPause: [KeyCombo(K.space)],
            .seekBackward1: [KeyCombo(K.left)],
            .seekForward1: [KeyCombo(K.right)],
            // macOS reserves Ctrl+Left/Right for Spaces, so ⌘ is offered as well.
            .seekBackward2: [KeyCombo(K.left, ctrl), KeyCombo(K.left, cmd)],
            .seekForward2: [KeyCombo(K.right, ctrl), KeyCombo(K.right, cmd)],
            .seekBackward3: [KeyCombo(K.left, shift)],
            .seekForward3: [KeyCombo(K.right, shift)],
            .seekBackward4: [KeyCombo(K.left, [ctrl, alt])],
            .seekForward4: [KeyCombo(K.right, [ctrl, alt])],
            .previousFrame: [KeyCombo(K.d)],
            .nextFrame: [KeyCombo(K.f)],
            .jumpToStart: [KeyCombo(K.backspace)],
            .jumpToTime: [KeyCombo(K.g)],
            .speedDown: [KeyCombo(K.x)],
            .speedUp: [KeyCombo(K.c)],
            .speedReset: [KeyCombo(K.z)],
            .volumeUp: [KeyCombo(K.up)],
            .volumeDown: [KeyCombo(K.down)],
            .mute: [KeyCombo(K.m)],
            .previousFile: [KeyCombo(K.pageUp)],
            .nextFile: [KeyCombo(K.pageDown)],
            .addBookmark: [KeyCombo(K.p)],
            .showBookmarks: [KeyCombo(K.h)],
            .toggleFullscreen: [KeyCombo(K.returnKey), KeyCombo(K.returnKey, alt), KeyCombo(K.keypadEnter)],
            .exitFullscreen: [KeyCombo(K.escape)],
            .toggleSubtitles: [KeyCombo(K.h, alt)],
            .cycleSubtitle: [KeyCombo(K.l, alt)],
            .loadSubtitle: [KeyCombo(K.o, alt)],
            .subtitleDelayDown: [KeyCombo(K.comma)],
            .subtitleDelayUp: [KeyCombo(K.period)],
            .subtitleDelayReset: [KeyCombo(K.slash)],
            .subtitleSizeUp: [KeyCombo(K.pageUp, alt)],
            .subtitleSizeDown: [KeyCombo(K.pageDown, alt)],
            .cycleAudio: [KeyCombo(K.a, alt)],
            .audioDelayDown: [KeyCombo(K.comma, shift)],
            .audioDelayUp: [KeyCombo(K.period, shift)],
            .audioDelayReset: [KeyCombo(K.slash, shift)],
            .windowSizeHalf: [KeyCombo(K.one)],
            .windowSizeNormal: [KeyCombo(K.two)],
            .windowSizeOneAndHalf: [KeyCombo(K.three)],
            .windowSizeDouble: [KeyCombo(K.four)],
            .stayOnTop: [KeyCombo(K.t, ctrl)],
            .showInfo: [KeyCombo(K.tab)],
            .openFile: [KeyCombo(K.o, ctrl), KeyCombo(K.f3)],
            .openFolder: [KeyCombo(K.f2)],
            .closePlayback: [KeyCombo(K.f4)],
            .preferences: [KeyCombo(K.f5)],
            .playlist: [KeyCombo(K.f6)],
            .saveFrame: [KeyCombo(K.e, ctrl)],
        ]
    }()
}

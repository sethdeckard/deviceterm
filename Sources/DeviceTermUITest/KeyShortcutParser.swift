// SPDX-License-Identifier: GPL-3.0-or-later
//
// KeyShortcutParser: parse "cmd+shift+left" into a virtual key code + flags.
//
// Pure, so the whole grammar is unit-testable without posting an event at
// anything. `InputDriver` turns the result into a real CGEvent.
//
// Virtual key codes are the ANSI layout constants from Carbon's Events.h,
// inlined as literals: importing Carbon for a table of integers would drag
// a framework into a binary that otherwise needs none, and the values are
// frozen by the hardware layout, not by the SDK.

import CoreGraphics
import Foundation

enum KeyShortcutParser {
    /// Modifier aliases. `opt`/`alt`/`option` all mean the same key, and
    /// agents write whichever their muscle memory produces.
    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "ctrl": .maskControl, "control": .maskControl,
        "opt": .maskAlternate, "alt": .maskAlternate, "option": .maskAlternate
    ]

    /// Named non-character keys. Letters and digits are resolved from the
    /// table below rather than special-cased.
    private static let namedKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 36,
        "tab": 48,
        "space": 49,
        "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]

    private static let characterKeys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25, "0": 29,
        "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39,
        ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50
    ]

    /// Parse a `+`-separated shortcut. Case-insensitive. Exactly one
    /// non-modifier key is required: "cmd" alone is not a gesture, and
    /// "cmd+t+w" is a typo rather than a chord we should guess at.
    static func parse(_ text: String) throws -> KeyShortcut {
        let tokens = text
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { throw KeyShortcutError.empty }

        var flags: CGEventFlags = []
        var key: (name: String, code: CGKeyCode)?

        for token in tokens {
            if let modifier = modifiers[token] {
                flags.insert(modifier)
                continue
            }
            guard let code = namedKeys[token] ?? characterKeys[token] else {
                throw KeyShortcutError.unknownToken(token)
            }
            if let existing = key {
                throw KeyShortcutError.multipleKeys(existing.name, token)
            }
            key = (token, code)
        }

        guard let key else { throw KeyShortcutError.missingKey }
        return KeyShortcut(keyCode: key.code, flags: flags)
    }
}

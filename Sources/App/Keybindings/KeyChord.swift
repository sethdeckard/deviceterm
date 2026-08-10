// SPDX-License-Identifier: GPL-3.0-or-later
//
// KeyChord: one keyboard shortcut as a value, a key plus modifiers.
//
// Centralizes construction of arrow-key equivalents in production code,
// and knows that an `NSMenuItem`'s key equivalent must be lowercase.
// AppKit reads an uppercase "T" as ⇧+"t", so a chord carrying shift in
// the string would disagree with its own modifier mask.
//
// Two matching hazards are handled here rather than at call sites, both
// measured against AppKit:
//
//   1. Reading `characters` on a non-key event RAISES
//      NSInternalInconsistencyException. `matches(_:)` checks the event
//      type first. This is required rather than defensive, because
//      `NSApp.currentEvent` is very often a mouse event.
//   2. `charactersIgnoringModifiers` keeps shift, so ⇧⌘[ arrives as "{"
//      and a naive comparison never matches. The unshifted character has
//      to be requested explicitly.

import AppKit

struct KeyChord: Hashable, Sendable {
    /// The non-modifier half of a chord. Arrows are named rather than
    /// spelled as characters because their key equivalents are function-key
    /// code points, not anything a person would type into a table.
    enum Key: Hashable, Sendable {
        case character(Character)
        case arrowLeft
        case arrowRight
        case arrowUp
        case arrowDown
    }

    let key: Key
    let modifiers: KeyModifiers

    /// The string handed to `NSMenuItem.keyEquivalent`. Always lowercase:
    /// shift lives in the modifier mask, never in the case of this string.
    var keyEquivalent: String {
        switch key {
        case let .character(character):
            return String(character).lowercased()

        case .arrowLeft:
            return Self.functionKey(NSLeftArrowFunctionKey)

        case .arrowRight:
            return Self.functionKey(NSRightArrowFunctionKey)

        case .arrowUp:
            return Self.functionKey(NSUpArrowFunctionKey)

        case .arrowDown:
            return Self.functionKey(NSDownArrowFunctionKey)
        }
    }

    /// Menu-style rendering, for example "⇧⌘T" or "⌥⌘←". Read by the drift
    /// guard's pinned map and by its failure diagnostics.
    var displayString: String {
        let glyph: String
        switch key {
        case let .character(character):
            glyph = String(character).uppercased()

        case .arrowLeft:
            glyph = "←"

        case .arrowRight:
            glyph = "→"

        case .arrowUp:
            glyph = "↑"

        case .arrowDown:
            glyph = "↓"
        }
        return modifiers.displayString + glyph
    }

    init(key: Key, modifiers: KeyModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Terse form for the catalog table: `KeyChord("t", .command)`.
    init(_ character: Character, _ modifiers: KeyModifiers) {
        self.init(key: .character(character), modifiers: modifiers)
    }

    init(_ key: Key, _ modifiers: KeyModifiers) {
        self.init(key: key, modifiers: modifiers)
    }

    /// Recover a chord from a built menu item, so the drift guard can
    /// compare the installed menu against the catalog. Returns nil for an
    /// item with no key equivalent.
    init?(menuItem: NSMenuItem) {
        let equivalent = menuItem.keyEquivalent
        guard let scalar = equivalent.unicodeScalars.first, !equivalent.isEmpty else {
            return nil
        }
        let modifiers = KeyModifiers(nsFlags: menuItem.keyEquivalentModifierMask)
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey:
            self.init(key: .arrowLeft, modifiers: modifiers)

        case NSRightArrowFunctionKey:
            self.init(key: .arrowRight, modifiers: modifiers)

        case NSUpArrowFunctionKey:
            self.init(key: .arrowUp, modifiers: modifiers)

        case NSDownArrowFunctionKey:
            self.init(key: .arrowDown, modifiers: modifiers)

        default:
            guard let character = equivalent.first else { return nil }
            self.init(key: .character(character), modifiers: modifiers)
        }
    }

    private static func functionKey(_ code: Int) -> String {
        String(utf16CodeUnits: [unichar(code)], count: 1)
    }

    /// Whether any of AppKit's readings of a keystroke names this chord's key.
    ///
    /// Pure, and split out from `matches(_:)` so the matching rule can be
    /// tested without synthesizing an `NSEvent`. Event synthesis re-derives
    /// characters from the key code against the active keyboard layout, so an
    /// event-based test would fail on Dvorak or a non-ANSI input source with
    /// nothing actually broken.
    ///
    /// AppKit offers three views of one key press and no single view covers
    /// every chord we bind, so any of them matching counts:
    ///
    ///   - `characters(byApplyingModifiers: [])` is the only one that
    ///     un-shifts punctuation, so it's what makes ⇧⌘[ read as "[" rather
    ///     than "{". It yields nothing at all for the arrow keys.
    ///   - `charactersIgnoringModifiers` and `characters` are what carry the
    ///     `NSRightArrowFunctionKey`-style code points arrow chords match on.
    ///
    /// The union is deliberate: these are all descriptions of the same
    /// physical key press, and the catalog forbids duplicate chords anyway.
    func matchesKey(readings: [String?]) -> Bool {
        let wanted = keyEquivalent
        return readings.contains { reading in
            guard let reading, !reading.isEmpty else { return false }
            return reading.lowercased() == wanted
        }
    }

    /// Whether `event` is this chord. Safe to call with any event,
    /// including `NSApp.currentEvent`, which is frequently a mouse event.
    func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        guard KeyModifiers(nsFlags: event.modifierFlags) == modifiers else { return false }
        return matchesKey(readings: [
            event.characters(byApplyingModifiers: []),
            event.charactersIgnoringModifiers,
            event.characters
        ])
    }
}

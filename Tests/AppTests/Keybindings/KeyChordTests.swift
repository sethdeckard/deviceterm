// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// Key-chord round-trips and matching hazards: shifted punctuation,
/// modifier noise, and non-key events.
@MainActor
struct KeyChordTests {
    /// The match depends on `keyCode`: `NSEvent.characters(byApplyingModifiers:)`
    /// re-derives the character from the key code and the active layout, and
    /// ignores the `characters:` argument entirely. Synthesizing with
    /// `keyCode: 0` makes every event report "a".
    private func keyEvent(
        characters: String,
        unshifted: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: unshifted,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    @Test("key equivalents render for characters and arrows", arguments: [
        (KeyChord("t", .command), "t"),
        (KeyChord(",", .command), ","),
        (KeyChord("=", .command), "="),
        (KeyChord("0", .command), "0")
    ])
    func rendersCharacterKeyEquivalents(chord: KeyChord, expected: String) {
        #expect(chord.keyEquivalent == expected)
    }

    @Test
    func rendersArrowKeyEquivalentsAsFunctionKeys() {
        let expected: [(KeyChord.Key, Int)] = [
            (.arrowLeft, NSLeftArrowFunctionKey),
            (.arrowRight, NSRightArrowFunctionKey),
            (.arrowUp, NSUpArrowFunctionKey),
            (.arrowDown, NSDownArrowFunctionKey)
        ]
        for (key, code) in expected {
            let chord = KeyChord(key, .command)
            #expect(chord.keyEquivalent == String(utf16CodeUnits: [unichar(code)], count: 1))
        }
    }

    @Test("display strings use Apple's ⌃⌥⇧⌘ order", arguments: [
        (KeyChord("t", .command), "⌘T"),
        (KeyChord("t", [.shift, .command]), "⇧⌘T"),
        (KeyChord("h", [.option, .command]), "⌥⌘H"),
        (KeyChord("f", [.control, .command]), "⌃⌘F"),
        (KeyChord(.arrowLeft, [.control, .shift]), "⌃⇧←"),
        (KeyChord(.arrowDown, [.option, .command]), "⌥⌘↓")
    ])
    func rendersDisplayStrings(chord: KeyChord, expected: String) {
        #expect(chord.displayString == expected)
    }

    @Test
    func uppercaseCharactersNormalizeToLowercaseEquivalents() {
        // AppKit reads "T" as ⇧+"t"; shift must live in the mask alone.
        #expect(KeyChord("T", .command).keyEquivalent == "t")
    }

    @Test
    func roundTripsThroughAMenuItem() {
        for entry in KeybindingCatalog.entries {
            let item = KeybindingCatalog.makeMenuItem(entry.action)
            #expect(KeyChord(menuItem: item) == entry.chord, "\(entry.action) did not round-trip")
        }
    }

    @Test
    func aMenuItemWithNoKeyEquivalentYieldsNoChord() {
        let item = NSMenuItem(title: "Unbound", action: nil, keyEquivalent: "")
        #expect(KeyChord(menuItem: item) == nil)
    }

    // MARK: - Matching hazards

    // The key-matching rule is tested through the pure `matchesKey(readings:)`
    // seam rather than through synthesized events. `NSEvent` re-derives its
    // characters from the key code against the active keyboard layout, so an
    // event-based test would assert that key code 33 is "[" (true on ANSI,
    // false on Dvorak or an international input source). That would fail
    // `make verify` on a contributor's machine with nothing broken.

    @Test
    func matchesShiftedPunctuationByItsUnshiftedReading() {
        // A real ⇧⌘[ reports `charactersIgnoringModifiers` as "{", since the
        // documented behavior is "as if no modifiers except Shift", while
        // `characters(byApplyingModifiers: [])` reports "[". Only the latter
        // can match, which is why the union exists.
        let chord = KeyChord("[", [.shift, .command])
        #expect(chord.matchesKey(readings: ["[", "{", "{"]))
        #expect(!chord.matchesKey(readings: ["{", "{"]), "must not match on the shifted reading alone")
    }

    @Test
    func matchesArrowChordsByTheirFunctionKeyCodePoint() {
        // Arrows are the mirror case. `characters(byApplyingModifiers:)`
        // yields nothing for them, and the code point arrives via the other
        // two readings. Without the union, every arrow chord (⇧⌘←, ⌥⌘→ and
        // the rest) would silently never match.
        let arrow = String(utf16CodeUnits: [unichar(NSRightArrowFunctionKey)], count: 1)
        let chord = KeyChord(.arrowRight, [.option, .command])
        #expect(chord.matchesKey(readings: [nil, arrow, arrow]))
        #expect(chord.matchesKey(readings: ["", arrow, arrow]))
        #expect(!chord.matchesKey(readings: [nil, nil, nil]))
    }

    @Test
    func matchingIsCaseInsensitiveAndRejectsOtherKeys() {
        let chord = KeyChord("t", .command)
        #expect(chord.matchesKey(readings: ["T"]))
        #expect(chord.matchesKey(readings: ["t"]))
        #expect(!chord.matchesKey(readings: ["y"]))
        #expect(!chord.matchesKey(readings: [nil, ""]))
    }

    @Test("modifier noise is masked away", arguments: [
        NSEvent.ModifierFlags([.option, .command, .function]),
        NSEvent.ModifierFlags([.option, .command, .numericPad]),
        NSEvent.ModifierFlags([.option, .command, .capsLock]),
        NSEvent.ModifierFlags([.option, .command, .function, .numericPad, .capsLock])
    ])
    func ignoresModifierNoiseCarriedByRealEvents(flags: NSEvent.ModifierFlags) {
        // Real events carry flags we don't model: .function rides on every
        // arrow key, .numericPad on many, .capsLock whenever it's on. Exact
        // `modifierFlags` equality would reject a genuine ⌥⌘→.
        #expect(KeyModifiers(nsFlags: flags) == [.option, .command])
    }

    @Test
    func rejectsAChordWithExtraRealModifiers() throws {
        let event = try #require(
            keyEvent(characters: "t", unshifted: "t", modifiers: [.shift, .command], keyCode: 17)
        )
        #expect(!KeyChord("t", .command).matches(event))
    }

    @Test
    func doesNotThrowOnNonKeyEvents() throws {
        // Reading `characters` on a non-key event raises
        // NSInternalInconsistencyException, and `NSApp.currentEvent` is very
        // often a mouse event, so this guard is a hard requirement.
        let mouse = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        #expect(!KeyChord("t", .command).matches(mouse))
    }
}

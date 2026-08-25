// SPDX-License-Identifier: GPL-3.0-or-later
//
// The key-versus-pointer arbitration behind focus-scoped device
// shortcuts.
//
// Both paths reach the same validator, so the whole rule rests on
// telling them apart. These pin the decision half. Whether a given
// `NSEvent` is a given chord is `KeyChord.matches`, covered in
// `KeyChordTests` against readings rather than synthesized events,
// because event synthesis re-derives characters from the active keyboard
// layout.

@testable import App
import AppKit
import Testing

@MainActor
struct DeviceShortcutScopeDecisionTests {
    private static let chord = KeyChord(.arrowLeft, .command)

    private static func keyEvent(type: NSEvent.EventType, chord: KeyChord) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: chord.modifiers.nsFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chord.keyEquivalent,
            charactersIgnoringModifiers: chord.keyEquivalent,
            isARepeat: false,
            keyCode: 0
        )
    }

    // MARK: - What each path is allowed

    @Test
    func aDeviceChordIsWithheldFromTheFallbackOnTheKeyPath() {
        // Reaching the fallback means no device pane holds focus, so the
        // key belongs to whatever does. AppKit hands a disabled item's
        // event down the chain rather than swallowing it, so ⌘← reaches
        // the focused terminal instead of vanishing.
        #expect(
            !DeviceShortcutScopeDecision.fallbackAllows(
                scope: .devicePane,
                origin: .keyEquivalent
            )
        )
    }

    @Test
    func aDeviceItemStaysClickableWithATerminalFocused() {
        // Explicit menu selection keeps the terminal-focused fallback
        // enabled: picking Device ▸ Home has one reading and no ambiguity
        // to resolve.
        #expect(
            DeviceShortcutScopeDecision.fallbackAllows(
                scope: .devicePane,
                origin: .pointerOrMenu
            )
        )
    }

    @Test(arguments: [MenuActionOrigin.keyEquivalent, .pointerOrMenu])
    func anAppScopedItemIsAllowedFromEitherPath(origin: MenuActionOrigin) {
        #expect(DeviceShortcutScopeDecision.fallbackAllows(scope: .app, origin: origin))
    }

    // MARK: - Reading the path off the current event

    @Test
    func noCurrentEventReadsAsThePointerPath() {
        // Unknown events keep the fallback enabled, so menu activation
        // remains available.
        #expect(
            DeviceShortcutScopeDecision.origin(currentEvent: nil, chord: Self.chord)
                == .pointerOrMenu
        )
    }

    @Test
    func aNonKeyEventReadsAsThePointerPath() throws {
        // `origin` must reject menu-tracking mouse events before chord
        // matching, and `NSApp.currentEvent` is very often one.
        let mouse = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
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
        #expect(
            DeviceShortcutScopeDecision.origin(currentEvent: mouse, chord: Self.chord)
                == .pointerOrMenu
        )
    }

    @Test
    func onlyAKeyDownReadsAsTheKeyPath() throws {
        // `KeyChord.matches` accepts a keyUp as well, which the device
        // pane's HID guard needs on both edges. Key-equivalent routing
        // runs on the keyDown, so a keyUp naming the same chord is some
        // other path and has to read as the pointer side.
        let chord = KeyChord("d", [.control, .shift])
        let pressed = try #require(Self.keyEvent(type: .keyDown, chord: chord))
        let released = try #require(Self.keyEvent(type: .keyUp, chord: chord))
        #expect(
            DeviceShortcutScopeDecision.origin(currentEvent: pressed, chord: chord)
                == .keyEquivalent
        )
        #expect(
            DeviceShortcutScopeDecision.origin(currentEvent: released, chord: chord)
                == .pointerOrMenu
        )
    }

    @Test
    func aKeyEventForAnotherChordReadsAsThePointerPath() throws {
        // Keyboard menu navigation also supplies a keyDown, but Return
        // must not match the item's chord. This synthesized event tests
        // only that mismatch; synthesized dispatch is not faithful.
        let carriageReturn = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
        #expect(
            DeviceShortcutScopeDecision.origin(currentEvent: carriageReturn, chord: Self.chord)
                == .pointerOrMenu
        )
    }
}

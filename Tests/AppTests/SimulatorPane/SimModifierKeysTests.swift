// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import Testing

/// A `flagsChanged` event as AppKit sends it: the class flag plus the
/// device-dependent bit for each side held.
@MainActor
private func flagsEvent(keyCode: UInt16, flags: UInt) -> NSEvent? {
    NSEvent.keyEvent(
        with: .flagsChanged,
        location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    )
}

@MainActor
private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, characters: String, flags: UInt = 0) -> NSEvent? {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )
}

private let shift = NSEvent.ModifierFlags.shift.rawValue
private let leftShift: UInt = 0x2
private let rightShift: UInt = 0x4

@Test("forwarded modifiers read pressed from their own side's bit", arguments: [
    (UInt16(0x38), NSEvent.ModifierFlags.shift.rawValue | 0x2, Bool?.some(true)),
    (UInt16(0x38), UInt(0), Bool?.some(false)),
    (UInt16(0x3C), NSEvent.ModifierFlags.shift.rawValue | 0x2, Bool?.some(false)),
    (UInt16(0x3B), NSEvent.ModifierFlags.control.rawValue | 0x1, Bool?.some(true)),
    (UInt16(0x3E), NSEvent.ModifierFlags.control.rawValue | 0x2000, Bool?.some(true)),
    (UInt16(0x3A), NSEvent.ModifierFlags.option.rawValue | 0x20, Bool?.some(true)),
    (UInt16(0x3D), NSEvent.ModifierFlags.option.rawValue | 0x40, Bool?.some(true))
])
func modifierPressedState(keyCode: UInt16, flags: UInt, pressed: Bool?) {
    #expect(SimModifierKeys.isPressed(keyCode: keyCode, modifierFlags: .init(rawValue: flags)) == pressed)
}

@Test("pressed key codes come from each side's bit")
func pressedKeyCodesBySide() {
    let flags = NSEvent.ModifierFlags(rawValue: shift | rightShift | NSEvent.ModifierFlags.option.rawValue | 0x20)
    #expect(SimModifierKeys.pressedKeyCodes(in: flags) == [0x3C, 0x3A])
    #expect(SimModifierKeys.pressedKeyCodes(in: []).isEmpty)
}

@Test("Command, Caps Lock and ordinary keys aren't forwarded as modifiers", arguments: [
    UInt16(0x37), 0x36, 0x39, 0x29
])
func unforwardedKeys(keyCode: UInt16) {
    let all = NSEvent.ModifierFlags([.command, .capsLock, .shift]).rawValue | 0xFFFF
    #expect(SimModifierKeys.isPressed(keyCode: keyCode, modifierFlags: .init(rawValue: all)) == nil)
}

@MainActor
struct SimulatorContentViewModifierTests {
    private final class KeyRecorder: SimulatorInputDelegate {
        var keys: [String] = []
        var simulatorPaneSupportsLiveTouchInput: Bool { true }
        var simulatorPaneSupportsMultitouchInput: Bool { true }
        var simulatorPaneSupportsEdgeGesture: Bool { false }
        func simulatorPaneDidTap(at point: CGPoint) {}
        func simulatorPaneDidTouch(at point: CGPoint, phase: TouchPhase, isEdgeGesture: Bool) {}
        func simulatorPaneDidMultitouch(phase: TouchPhase, finger1: CGPoint, finger2: CGPoint) {}
        func simulatorPaneDidSwipe(from start: CGPoint, to end: CGPoint, durationMs: Int) {}
        func simulatorPaneDidPinch(fromF1: CGPoint, fromF2: CGPoint, toF1: CGPoint, toF2: CGPoint, durationMs: Int) {}
        func simulatorPaneKeyDown(keyCode: UInt16) { keys.append("down \(keyCode)") }
        func simulatorPaneKeyUp(keyCode: UInt16) { keys.append("up \(keyCode)") }
        func simulatorPaneDidCrown(delta: Double) {}
    }

    @Test
    func shiftSemicolonReachesTheDeviceAsAColon() throws {
        let view = SimulatorContentView()
        let recorder = KeyRecorder()
        view.inputDelegate = recorder
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x38, flags: shift | leftShift)))
        view.keyDown(with: try #require(keyEvent(.keyDown, keyCode: 0x29, characters: ":", flags: shift | leftShift)))
        view.keyUp(with: try #require(keyEvent(.keyUp, keyCode: 0x29, characters: ":", flags: shift | leftShift)))
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x38, flags: 0)))
        #expect(recorder.keys == ["down 56", "down 41", "up 41", "up 56"])
        #expect(view.heldModifierKeys.isEmpty)
    }

    @Test
    func releasingOneShiftKeepsTheOtherHeld() throws {
        let view = SimulatorContentView()
        let recorder = KeyRecorder()
        view.inputDelegate = recorder
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x38, flags: shift | leftShift)))
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x3C, flags: shift | leftShift | rightShift)))
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x3C, flags: shift | leftShift)))
        #expect(recorder.keys == ["down 56", "down 60", "up 60"])
        #expect(view.heldModifierKeys == [0x38])
    }

    @Test
    func aReleaseWithoutItsPressIsNotForwarded() throws {
        // Shift held before the pane had focus: only its release arrives.
        let view = SimulatorContentView()
        let recorder = KeyRecorder()
        view.inputDelegate = recorder
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x38, flags: 0)))
        #expect(recorder.keys.isEmpty)
    }

    @Test
    func commandIsNotForwarded() throws {
        let view = SimulatorContentView()
        let recorder = KeyRecorder()
        view.inputDelegate = recorder
        let command = NSEvent.ModifierFlags.command.rawValue | 0x8
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x37, flags: command)))
        #expect(recorder.keys.isEmpty)
    }

    @Test
    func shiftHeldThroughAFocusChangeIsPressedAgainBeforeTheNextKey() throws {
        let view = SimulatorContentView()
        let recorder = KeyRecorder()
        view.inputDelegate = recorder
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x38, flags: shift | leftShift)))
        _ = view.resignFirstResponder()
        // Focus is back and Shift was never let go: the next key shows it held.
        view.keyDown(with: try #require(keyEvent(.keyDown, keyCode: 0x29, characters: ":", flags: shift | leftShift)))
        #expect(recorder.keys == ["down 56", "up 56", "down 56", "down 41"])
        #expect(view.heldModifierKeys == [0x38])
    }

    @Test
    func aModifierReleasedElsewhereIsReleasedBeforeTheNextKey() throws {
        // A missed Shift release: the next key's flags show it isn't held, so
        // the stale press is released before the key goes.
        let view = SimulatorContentView()
        let recorder = KeyRecorder()
        view.inputDelegate = recorder
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x38, flags: shift | leftShift)))
        view.keyDown(with: try #require(keyEvent(.keyDown, keyCode: 0x29, characters: ";")))
        #expect(recorder.keys == ["down 56", "up 56", "down 41"])
        #expect(view.heldModifierKeys.isEmpty)
    }

    @Test
    func heldModifiersAreReleasedWhenFocusLeaves() throws {
        let view = SimulatorContentView()
        let recorder = KeyRecorder()
        view.inputDelegate = recorder
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x38, flags: shift | leftShift)))
        let option = NSEvent.ModifierFlags.option.rawValue | 0x20
        view.flagsChanged(with: try #require(flagsEvent(keyCode: 0x3A, flags: shift | leftShift | option)))
        _ = view.resignFirstResponder()
        #expect(recorder.keys == ["down 56", "down 58", "up 56", "up 58"])
        #expect(view.heldModifierKeys.isEmpty)
    }
}

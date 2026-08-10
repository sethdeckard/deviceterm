// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// kVK → HID usage translation table. Indigo expects USB HID
// usage codes, not macOS HIToolbox virtual keys; without this
// translation every key sent through the bridge is gibberish (see
// SimHIDClient.h's keyboard comment).
//
// The table itself is the canonical reference, and these tests pin
// it against `<HIToolbox/Events.h>` for kVK values and the USB
// HID Usage Tables (Keyboard/Keypad page 0x07) for HID values.

@Test(
    "ANSI letters",
    arguments: [
        (UInt32(0x00), UInt32(0x04), "a"),
        (UInt32(0x0B), UInt32(0x05), "b"),
        (UInt32(0x08), UInt32(0x06), "c"),
        (UInt32(0x02), UInt32(0x07), "d"),
        (UInt32(0x0E), UInt32(0x08), "e"),
        (UInt32(0x22), UInt32(0x0C), "i"),
        (UInt32(0x01), UInt32(0x16), "s"),
        (UInt32(0x10), UInt32(0x1C), "y"),
        (UInt32(0x06), UInt32(0x1D), "z")
    ]
)
func kVKLetterTranslates(kvk: UInt32, hid: UInt32, label: String) {
    let actual = KeyboardInputMap.kVKToHIDUsage(kvk)
    #expect(
        actual == hid,
        "kVK 0x\(String(kvk, radix: 16)) ('\(label)') -> HID 0x\(String(hid, radix: 16))"
    )
}

@Test(
    "Top-row digits",
    arguments: [
        (UInt32(0x12), UInt32(0x1E), "1"),
        (UInt32(0x13), UInt32(0x1F), "2"),
        (UInt32(0x14), UInt32(0x20), "3"),
        (UInt32(0x1A), UInt32(0x24), "7"),
        (UInt32(0x1C), UInt32(0x25), "8"),
        (UInt32(0x1D), UInt32(0x27), "0")  // 0 sits after 9
    ]
)
func kVKDigitTranslates(kvk: UInt32, hid: UInt32, label: String) {
    let actual = KeyboardInputMap.kVKToHIDUsage(kvk)
    #expect(
        actual == hid,
        "kVK 0x\(String(kvk, radix: 16)) ('\(label)') -> HID 0x\(String(hid, radix: 16))"
    )
}

@Test
func kVKEditingKeysTranslate() {
    #expect(KeyboardInputMap.kVKToHIDUsage(0x24) == 0x28)  // return
    #expect(KeyboardInputMap.kVKToHIDUsage(0x35) == 0x29)  // escape
    #expect(KeyboardInputMap.kVKToHIDUsage(0x33) == 0x2A)  // backspace
    #expect(KeyboardInputMap.kVKToHIDUsage(0x30) == 0x2B)  // tab
    #expect(KeyboardInputMap.kVKToHIDUsage(0x31) == 0x2C)  // space
}

@Test
func kVKModifiersTranslate() {
    // Modifier codes live in the HID usage range 0xE0-0xE7. Used
    // to be a silent bug: text() held kVK 0x38 thinking it was
    // shift, but the bridge sent that as HID 0x38 (slash), so Shift
    // wasn't pressed and uppercase letters came out lowercase.
    #expect(KeyboardInputMap.kVKToHIDUsage(0x38) == 0xE1)  // left shift
    #expect(KeyboardInputMap.kVKToHIDUsage(0x37) == 0xE3)  // left command (GUI)
    #expect(KeyboardInputMap.kVKToHIDUsage(0x3A) == 0xE2)  // left option
    #expect(KeyboardInputMap.kVKToHIDUsage(0x3B) == 0xE0)  // left control
    #expect(KeyboardInputMap.kVKToHIDUsage(0x3C) == 0xE5)  // right shift
}

@Test
func kVKArrowsTranslate() {
    #expect(KeyboardInputMap.kVKToHIDUsage(0x7E) == 0x52)  // up
    #expect(KeyboardInputMap.kVKToHIDUsage(0x7D) == 0x51)  // down
    #expect(KeyboardInputMap.kVKToHIDUsage(0x7B) == 0x50)  // left
    #expect(KeyboardInputMap.kVKToHIDUsage(0x7C) == 0x4F)  // right
}

@Test
func kVKFunctionKeysTranslate() {
    // F1–F12. F13+ is not covered.
    #expect(KeyboardInputMap.kVKToHIDUsage(0x7A) == 0x3A)  // F1
    #expect(KeyboardInputMap.kVKToHIDUsage(0x78) == 0x3B)  // F2
    #expect(KeyboardInputMap.kVKToHIDUsage(0x67) == 0x44)  // F11
    #expect(KeyboardInputMap.kVKToHIDUsage(0x6F) == 0x45)  // F12
}

@Test
func kVKUnknownReturnsNil() {
    // Codes outside the ANSI layout (e.g. international keys,
    // F13+, keypad) return nil so `pane.input.key` can surface
    // unsupportedKeyCode rather than silently sending HID 0x00.
    #expect(KeyboardInputMap.kVKToHIDUsage(0xFF) == nil)
    #expect(KeyboardInputMap.kVKToHIDUsage(0x99) == nil)
    // F13 (kVK 0x69) is currently unmapped. Pinned so the
    // backlog'd broader-coverage work surfaces in CI when added.
    #expect(KeyboardInputMap.kVKToHIDUsage(0x69) == nil)
}

@Test
func hidShiftMatchesTranslationFromKVKShift() {
    // `hidShift` (0xE1) MUST equal `kVKToHIDUsage(kVK_Shift)`.
    // The translation function is the single source of truth;
    // `hidShift` is a precomputed convenience for the text()
    // hot path. If these ever drift, shifted typing breaks.
    #expect(KeyboardInputMap.hidShift == KeyboardInputMap.kVKToHIDUsage(0x38))
}

// MARK: - asciiKeyMap regression

@Test
func asciiKeyMapStoresHIDCodes() {
    // Regression for a keyboard bug: asciiKeyMap was storing
    // kVK codes, which got sent to Indigo as HID and produced
    // gibberish. Confirm the map is built with HID values now.
    let map = KeyboardInputMap.asciiKeyMap
    #expect(map["a"]?.keyCode == 0x04, "'a' must store HID 0x04, not kVK 0x00")
    #expect(map["z"]?.keyCode == 0x1D, "'z' must store HID 0x1D, not kVK 0x06")
    #expect(map["1"]?.keyCode == 0x1E, "'1' must store HID 0x1E, not kVK 0x12")
    #expect(map["0"]?.keyCode == 0x27, "'0' must store HID 0x27, not kVK 0x1D")
    #expect(map[" "]?.keyCode == 0x2C, "space must store HID 0x2C, not kVK 0x31")
    #expect(map["\n"]?.keyCode == 0x28, "newline must store HID 0x28, not kVK 0x24")
    // Shift flag survives the translation pass.
    #expect(map["A"]?.shift == true)
    #expect(map["a"]?.shift == false)
    #expect(map["!"]?.shift == true)
}

// MARK: - PaneCoordinator-level rejection for unknown kVK

@Test
func keyOnUnknownKeyCodeThrowsUnsupportedKeyCode() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createPane(
        target: .sim(udid: "unknown-kvk"),
        sessionId: session,
        acquire: {
            PaneCoordinator.AcquiredBackend(
                backend: backend,
                family: "phone",
                deviceType: "iPhone"
            )
        }
    )
    await #expect(throws: PaneError.unsupportedKeyCode(paneId: pane.paneId, keyCode: 0xFF)) {
        try await coordinator.key(paneId: pane.paneId, as: .session(session), keyCode: 0xFF, down: true)
    }
    #expect(backend.keyDownUsages.isEmpty)
    #expect(backend.keyUpUsages.isEmpty)
}

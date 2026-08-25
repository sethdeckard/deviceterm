// SPDX-License-Identifier: GPL-3.0-or-later
//
// KeyboardInputMap: keyboard translation tables for `pane.input.key`
// and `pane.input.text`.
//
// Two pieces, both static and stateless:
//
// 1. `kVKToHIDUsage(_:)` maps macOS HIToolbox virtual key codes
//    (`kVK_*`, from `NSEvent.keyCode`) to USB HID usage codes
//    (Keyboard/Keypad page 0x07). Indigo's keyboard transport speaks
//    HID; macOS's NSEvent speaks kVK. The number spaces don't overlap
//    (e.g. 'a' is kVK 0x00 but HID 0x04), so the daemon translates at
//    its bridge boundary. Without this, every key sent through
//    `SimHIDClient` is gibberish.
//
// 2. `asciiKeyMap`: ASCII character → (HID keyCode, requires shift).
//    Built once at static init: characters are authored as kVK rows
//    so a reviewer can diff them row-by-row against the kVK tables
//    before translation collapses to HID via `kVKToHIDUsage`. The
//    translation function is the single source of truth; `hidShift`
//    is a precomputed convenience for the `text()` hot path.
//
// Lives in its own file (rather than nested inside `PaneCoordinator`)
// because it's pure static logic with no actor-state coupling, and
// because broader keycode coverage (international layouts, F13+,
// keypad, media keys) is not covered, and would be much easier to
// extend in a dedicated file than amongst PaneCoordinator's
// pane-lifecycle code.
//
// Source: macOS `<HIToolbox/Events.h>` for kVK values; USB HID Usage
// Tables (Keyboard/Keypad page 0x07) for HID values.

import Foundation

public enum KeyboardInputMap {
    /// USB HID usage code for the Shift modifier (Left Shift).
    /// `SimHIDClient` sends these straight to Indigo as-is, so the
    /// daemon must speak HID, not macOS kVK, at the bridge boundary.
    public static let hidShift: UInt32 = 0xE1

    /// ASCII → (HID usage keyCode, requires shift). Built once at
    /// static init: keyed by character, with each entry's HID code
    /// resolved through `kVKToHIDUsage` so the translation table is
    /// the single source of truth. Characters outside this map
    /// throw `unsupportedCharacter` at the call site. International
    /// layouts, F13+, keypad, and media keys are not covered.
    public static let asciiKeyMap: [Character: (keyCode: UInt32, shift: Bool)] = {
        // Each entry pairs an unshifted character with its shifted
        // counterpart on the same kVK key, so reviewers can diff the
        // layout row-by-row before translation collapses to HID.
        struct ShiftPair {
            let unshifted: Character
            let shifted: Character
            let kvk: UInt32
        }
        var kvkMap: [Character: (kvk: UInt32, shift: Bool)] = [:]
        // Letters: share a kVK between cases; shift selects case.
        let letters: [(Character, UInt32)] = [
            ("a", 0x00),
            ("b", 0x0B),
            ("c", 0x08),
            ("d", 0x02),
            ("e", 0x0E),
            ("f", 0x03),
            ("g", 0x05),
            ("h", 0x04),
            ("i", 0x22),
            ("j", 0x26),
            ("k", 0x28),
            ("l", 0x25),
            ("m", 0x2E),
            ("n", 0x2D),
            ("o", 0x1F),
            ("p", 0x23),
            ("q", 0x0C),
            ("r", 0x0F),
            ("s", 0x01),
            ("t", 0x11),
            ("u", 0x20),
            ("v", 0x09),
            ("w", 0x0D),
            ("x", 0x07),
            ("y", 0x10),
            ("z", 0x06)
        ]
        for (char, kvk) in letters {
            kvkMap[char] = (kvk, false)
            if let upper = char.uppercased().first {
                kvkMap[upper] = (kvk, true)
            }
        }
        let digits: [ShiftPair] = [
            ShiftPair(unshifted: "0", shifted: ")", kvk: 0x1D),
            ShiftPair(unshifted: "1", shifted: "!", kvk: 0x12),
            ShiftPair(unshifted: "2", shifted: "@", kvk: 0x13),
            ShiftPair(unshifted: "3", shifted: "#", kvk: 0x14),
            ShiftPair(unshifted: "4", shifted: "$", kvk: 0x15),
            ShiftPair(unshifted: "5", shifted: "%", kvk: 0x17),
            ShiftPair(unshifted: "6", shifted: "^", kvk: 0x16),
            ShiftPair(unshifted: "7", shifted: "&", kvk: 0x1A),
            ShiftPair(unshifted: "8", shifted: "*", kvk: 0x1C),
            ShiftPair(unshifted: "9", shifted: "(", kvk: 0x19)
        ]
        for pair in digits {
            kvkMap[pair.unshifted] = (pair.kvk, false)
            kvkMap[pair.shifted] = (pair.kvk, true)
        }
        kvkMap[" "] = (0x31, false)
        kvkMap["\n"] = (0x24, false)  // Return
        kvkMap["\t"] = (0x30, false)  // Tab
        let punct: [ShiftPair] = [
            ShiftPair(unshifted: "-", shifted: "_", kvk: 0x1B),
            ShiftPair(unshifted: "=", shifted: "+", kvk: 0x18),
            ShiftPair(unshifted: "[", shifted: "{", kvk: 0x21),
            ShiftPair(unshifted: "]", shifted: "}", kvk: 0x1E),
            ShiftPair(unshifted: "\\", shifted: "|", kvk: 0x2A),
            ShiftPair(unshifted: ";", shifted: ":", kvk: 0x29),
            ShiftPair(unshifted: "'", shifted: "\"", kvk: 0x27),
            ShiftPair(unshifted: ",", shifted: "<", kvk: 0x2B),
            ShiftPair(unshifted: ".", shifted: ">", kvk: 0x2F),
            ShiftPair(unshifted: "/", shifted: "?", kvk: 0x2C),
            ShiftPair(unshifted: "`", shifted: "~", kvk: 0x32)
        ]
        for pair in punct {
            kvkMap[pair.unshifted] = (pair.kvk, false)
            kvkMap[pair.shifted] = (pair.kvk, true)
        }
        // Collapse kVK → HID at static-init time. Drop any character
        // whose kVK doesn't map (shouldn't happen for our curated
        // ASCII set, but `compactMapValues` keeps the type total).
        var hidMap: [Character: (keyCode: UInt32, shift: Bool)] = [:]
        for (char, entry) in kvkMap {
            if let hid = kVKToHIDUsage(entry.kvk) {
                hidMap[char] = (hid, entry.shift)
            }
        }
        return hidMap
    }()

    /// Convert a macOS HIToolbox virtual key code (kVK_*, from
    /// `NSEvent.keyCode`) to its USB HID usage code. Indigo's
    /// keyboard transport expects HID, not virtual keys (different
    /// number spaces: 'a' is kVK 0x00 but HID 0x04); without this
    /// translation, every key sent through the bridge is gibberish.
    ///
    /// Source: macOS `<HIToolbox/Events.h>` for kVK values, USB HID
    /// Usage Tables (Keyboard/Keypad page 0x07) for HID values.
    ///
    /// Returns `nil` for kVK values outside the ANSI layout the
    /// table covers; broader coverage (international keys, F13+,
    /// keypad, media keys) is not covered.
    public static func kVKToHIDUsage(_ kvk: UInt32) -> UInt32? {
        switch kvk {
        // Letters
        case 0x00:
            return 0x04  // a

        case 0x0B:
            return 0x05  // b

        case 0x08:
            return 0x06  // c

        case 0x02:
            return 0x07  // d

        case 0x0E:
            return 0x08  // e

        case 0x03:
            return 0x09  // f

        case 0x05:
            return 0x0A  // g

        case 0x04:
            return 0x0B  // h

        case 0x22:
            return 0x0C  // i

        case 0x26:
            return 0x0D  // j

        case 0x28:
            return 0x0E  // k

        case 0x25:
            return 0x0F  // l

        case 0x2E:
            return 0x10  // m

        case 0x2D:
            return 0x11  // n

        case 0x1F:
            return 0x12  // o

        case 0x23:
            return 0x13  // p

        case 0x0C:
            return 0x14  // q

        case 0x0F:
            return 0x15  // r

        case 0x01:
            return 0x16  // s

        case 0x11:
            return 0x17  // t

        case 0x20:
            return 0x18  // u

        case 0x09:
            return 0x19  // v

        case 0x0D:
            return 0x1A  // w

        case 0x07:
            return 0x1B  // x

        case 0x10:
            return 0x1C  // y

        case 0x06:
            return 0x1D  // z

        // Top-row digits
        case 0x12:
            return 0x1E  // 1

        case 0x13:
            return 0x1F  // 2

        case 0x14:
            return 0x20  // 3

        case 0x15:
            return 0x21  // 4

        case 0x17:
            return 0x22  // 5

        case 0x16:
            return 0x23  // 6

        case 0x1A:
            return 0x24  // 7

        case 0x1C:
            return 0x25  // 8

        case 0x19:
            return 0x26  // 9

        case 0x1D:
            return 0x27  // 0

        // Editing + whitespace
        case 0x24:
            return 0x28  // return

        case 0x35:
            return 0x29  // escape

        case 0x33:
            return 0x2A  // delete / backspace

        case 0x30:
            return 0x2B  // tab

        case 0x31:
            return 0x2C  // space

        case 0x1B:
            return 0x2D  // -

        case 0x18:
            return 0x2E  // =

        case 0x21:
            return 0x2F  // [

        case 0x1E:
            return 0x30  // ]

        case 0x2A:
            return 0x31  // \

        case 0x29:
            return 0x33  // ;

        case 0x27:
            return 0x34  // '

        case 0x32:
            return 0x35  // `

        case 0x2B:
            return 0x36  // ,

        case 0x2F:
            return 0x37  // .

        case 0x2C:
            return 0x38  // /

        case 0x39:
            return 0x39  // caps lock

        // Arrows
        case 0x7E:
            return 0x52  // up

        case 0x7D:
            return 0x51  // down

        case 0x7B:
            return 0x50  // left

        case 0x7C:
            return 0x4F  // right

        // Function keys F1–F12
        case 0x7A:
            return 0x3A  // F1

        case 0x78:
            return 0x3B  // F2

        case 0x63:
            return 0x3C  // F3

        case 0x76:
            return 0x3D  // F4

        case 0x60:
            return 0x3E  // F5

        case 0x61:
            return 0x3F  // F6

        case 0x62:
            return 0x40  // F7

        case 0x64:
            return 0x41  // F8

        case 0x65:
            return 0x42  // F9

        case 0x6D:
            return 0x43  // F10

        case 0x67:
            return 0x44  // F11

        case 0x6F:
            return 0x45  // F12

        // Modifiers
        case 0x37:
            return 0xE3  // left command (GUI)

        case 0x38:
            return 0xE1  // left shift

        case 0x3A:
            return 0xE2  // left alt/option

        case 0x3B:
            return 0xE0  // left control

        case 0x36:
            return 0xE7  // right command

        case 0x3C:
            return 0xE5  // right shift

        case 0x3D:
            return 0xE6  // right alt

        case 0x3E:
            return 0xE4  // right control

        default:
            return nil
        }
    }
}

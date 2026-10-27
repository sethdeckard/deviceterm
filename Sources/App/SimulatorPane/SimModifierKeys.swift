// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The modifier keys a device pane forwards, and whether a `flagsChanged`
/// event pressed or released one.
///
/// AppKit reports a modifier key only through `flagsChanged`, never
/// `keyDown`/`keyUp`, so a pane that forwards only those never sends Shift,
/// and Shift-`;` arrives on the device as `;`. Command is left out because a
/// Command chord is the app's (`SimulatorContentView.keyDown` keeps the key
/// half), and Caps Lock because it toggles rather than holds.
enum SimModifierKeys {
    /// The device-dependent flag bit for each forwarded key, by virtual key
    /// code. Left and right report separately, so releasing one Shift while
    /// the other is held reads as that key's release.
    private static let deviceFlags: [UInt16: UInt] = [
        0x38: 0x0000_0002,  // left shift
        0x3C: 0x0000_0004,  // right shift
        0x3B: 0x0000_0001,  // left control
        0x3E: 0x0000_2000,  // right control
        0x3A: 0x0000_0020,  // left option
        0x3D: 0x0000_0040   // right option
    ]

    /// Every forwarded modifier `modifierFlags` shows held.
    static func pressedKeyCodes(in modifierFlags: NSEvent.ModifierFlags) -> Set<UInt16> {
        Set(deviceFlags.compactMap { keyCode, bit in modifierFlags.rawValue & bit != 0 ? keyCode : nil })
    }

    /// `true` when the event left the forwarded modifier `keyCode` down,
    /// `false` when it left it up, nil when the pane doesn't forward that key.
    static func isPressed(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool? {
        guard let bit = deviceFlags[keyCode] else { return nil }
        return modifierFlags.rawValue & bit != 0
    }
}

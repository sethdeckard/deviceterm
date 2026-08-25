// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for `pane.input.key`.
///
/// A discrete keydown/keyup, so the GUI's NSEvent pipeline can forward
/// press and release 1:1.
public struct KeyParams: Codable, Sendable {
    public let paneId: String
    /// macOS HIToolbox virtual key code (kVK_*, the value from
    /// `NSEvent.keyCode`). The daemon translates to the USB HID
    /// usage code Indigo expects via
    /// `KeyboardInputMap.kVKToHIDUsage`. kVK values outside the
    /// translation table surface as `invalidParams`.
    public let keyCode: UInt32
    /// `true` for press, `false` for release. Discrete so the
    /// GUI's NSEvent pipeline can forward keyDown/keyUp 1:1.
    public let down: Bool

    public init(paneId: String, keyCode: UInt32, down: Bool) {
        self.paneId = paneId
        self.keyCode = keyCode
        self.down = down
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

/// Whether a pane's device has a simulated hardware keyboard. Returned by
/// both `pane.hardwareKeyboard.set` and `pane.hardwareKeyboard.state`.
public struct PaneHardwareKeyboardState: Codable, Sendable, Equatable {
    /// The pane's HID client's hardware-keyboard mode, `false` when the pane
    /// has no client. A device that rebooted or was reattached reports
    /// `false`: the keyboard went away with the old client's connection.
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

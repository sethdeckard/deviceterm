// SPDX-License-Identifier: GPL-3.0-or-later

/// `pane.hardwareKeyboard.set` parameters: whether the pane's device gets a
/// simulated hardware keyboard.
public struct PaneHardwareKeyboardSetParams: Codable, Sendable, Equatable {
    public let paneId: String
    /// `true` registers a virtual keyboard, which the device counts as
    /// attached hardware, so it hides its on-screen keyboard. `false` removes
    /// it and brings the on-screen keyboard back.
    public let enabled: Bool

    public init(paneId: String, enabled: Bool) {
        self.paneId = paneId
        self.enabled = enabled
    }
}

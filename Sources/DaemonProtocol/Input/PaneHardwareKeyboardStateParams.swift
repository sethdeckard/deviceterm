// SPDX-License-Identifier: GPL-3.0-or-later

/// `pane.hardwareKeyboard.state` parameters.
public struct PaneHardwareKeyboardStateParams: Codable, Sendable, Equatable {
    public let paneId: String

    public init(paneId: String) {
        self.paneId = paneId
    }
}

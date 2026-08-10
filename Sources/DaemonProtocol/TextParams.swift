// SPDX-License-Identifier: GPL-3.0-or-later
//
// TextParams: wire shape for `pane.input.text`.
//
// ASCII text input; the daemon translates each character to HID
// usages.

public struct TextParams: Codable, Sendable {
    public let paneId: String
    /// ASCII string. Each character must appear in the daemon's
    /// keymap (`PaneCoordinator.asciiKeyMap`); unsupported
    /// characters surface as `invalidParams` so the caller can
    /// fix them rather than silently losing input.
    public let text: String

    public init(paneId: String, text: String) {
        self.paneId = paneId
        self.text = text
    }
}

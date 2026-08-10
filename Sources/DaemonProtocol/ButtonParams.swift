// SPDX-License-Identifier: GPL-3.0-or-later
//
// ButtonParams: wire shape for `pane.input.button`.
//
// A hardware button press. `button` stays a raw string on the wire;
// the daemon validates it against `HardwareButton(rawValue:)` in the
// handler so an unknown value surfaces as `invalidParams` with the
// accepted set, rather than a generic decode failure.

public struct ButtonParams: Codable, Sendable {
    public let paneId: String
    /// One of `home`, `lock`, `side`, `applePay`, `siri`.
    public let button: String

    public init(paneId: String, button: String) {
        self.paneId = paneId
        self.button = button
    }
}

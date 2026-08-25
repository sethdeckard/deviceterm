// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for `pane.input.touch`.
///
/// A single live single-finger touch update (the GUI drag path streams
/// down -> moves -> up).
public struct TouchParams: Codable, Sendable {
    public let paneId: String
    public let x: Double
    public let y: Double
    public let phase: String

    public init(paneId: String, x: Double, y: Double, phase: String) {
        self.paneId = paneId
        self.x = x
        self.y = y
        self.phase = phase
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// CrownParams: wire shape for `pane.input.crown`.
//
// Drives the watchOS Digital Crown.

public struct CrownParams: Codable, Sendable {
    public let paneId: String
    /// Signed Digital Crown rotation: sign is the direction
    /// (positive = forward/down), magnitude is the distance in the
    /// bridge's raw crown unit.
    public let delta: Double
    /// Accepted for forward-compat but currently **ignored**, since the
    /// SimulatorKit crown builder takes only a delta. Kept on the
    /// wire so the contract is stable if a velocity-bearing builder
    /// ever appears.
    public let velocity: Double?
    /// Optional. `0` (default) sends the whole rotation at once; a
    /// positive value sub-steps it over the duration at ~60Hz.
    public let durationMs: Int?

    public init(paneId: String, delta: Double, velocity: Double?, durationMs: Int?) {
        self.paneId = paneId
        self.delta = delta
        self.velocity = velocity
        self.durationMs = durationMs
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// AXSweepParams: wire shape for `pane.ax.sweep`.
//
// Requests a grid sweep of accessibility elements across the display.

public struct AXSweepParams: Codable, Sendable {
    public let paneId: String
    /// Grid step in normalized [0,1] axis units. Optional; the
    /// daemon defaults to `AXSweep.defaultStep` (0.05) and clamps
    /// out-of-range values into `[AXSweep.minStep, AXSweep.maxStep]`.
    public let step: Double?

    public init(paneId: String, step: Double?) {
        self.paneId = paneId
        self.step = step
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for `pane.ax.sweep`.
///
/// Requests a grid sweep of accessibility elements across the display.
public struct AXSweepParams: Codable, Sendable {
    public let paneId: String
    /// Grid step in normalized [0,1] axis units. Optional; the
    /// daemon defaults to `AXSweep.defaultStep` (0.05) and clamps
    /// out-of-range values into `[AXSweep.minStep, AXSweep.maxStep]`.
    public let step: Double?
    /// Milliseconds the walk may spend scheduling bridge calls. Optional;
    /// the daemon defaults to `AXSweepBudget.defaultMs` and clamps into
    /// `[0, AXSweepBudget.maxMs]`, echoing what it used in the sweep root.
    ///
    /// Optional for version skew as well as for convenience: a daemon that
    /// predates the field ignores it and walks under its own fixed bound,
    /// so a caller asking for longer gets a shorter, truncated answer
    /// rather than an error.
    public let budgetMs: Int?

    public init(paneId: String, step: Double?, budgetMs: Int?) {
        self.paneId = paneId
        self.step = step
        self.budgetMs = budgetMs
    }
}

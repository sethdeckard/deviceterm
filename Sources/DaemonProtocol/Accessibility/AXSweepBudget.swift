// SPDX-License-Identifier: GPL-3.0-or-later

/// How long an `ax sweep` may spend scheduling bridge calls: the budget it
/// gets when the caller names none, and the ceiling it accepts.
///
/// Shared because both sides need these numbers for different reasons. The
/// daemon substitutes the default before walking and clamps a caller's request
/// to `maxMs`. A client needs `maxMs` to size its own response timeout, since
/// the ceiling is also the longest another caller's sweep can hold the pane's
/// accessibility queue, and every `ax` verb can end up queued behind one.
public enum AXSweepBudget {
    /// Budget for a sweep that names none. Sized against a per-bridge-call
    /// cost of roughly 5ms, at which the default grid fits with room to spare
    /// and the finest legal one does not. Whether either finishes is a
    /// property of the host, not of this number, so a caller reads `truncated`
    /// rather than inferring coverage from the step.
    public static let defaultMs: Int = 10_000

    /// Largest budget the daemon honors. A sweep holds the pane's serial
    /// accessibility queue for its whole walk, so every other `ax` read on
    /// that pane waits behind it; the ceiling is what stops one caller
    /// parking that queue indefinitely.
    ///
    /// A larger request is clamped rather than refused, because a budget is
    /// a spending limit rather than a description of the work: a caller who
    /// asks for more time gets all the time there is and a result that says
    /// how far it got. The clamped value is echoed in the sweep root so the
    /// clamp is visible.
    public static let maxMs: Int = 60_000

    /// Resolve a caller's requested budget: the default when unspecified,
    /// otherwise the request held inside `[0, maxMs]`.
    ///
    /// Zero is legal and means what it says. Such a sweep answers
    /// immediately, truncated, having queried nothing, which is the same
    /// answer one whose budget went while it waited for the queue gives.
    public static func clamp(_ requested: Int?) -> Int {
        guard let requested else { return defaultMs }
        return min(maxMs, max(0, requested))
    }
}

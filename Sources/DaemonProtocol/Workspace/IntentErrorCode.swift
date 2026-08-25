// SPDX-License-Identifier: GPL-3.0-or-later

/// Intent-layer error codes the daemon has to
/// recognize, not just relay.
///
/// The GUI's `IntentError` owns the full set and most of them are
/// pass-through: the daemon wraps whatever code comes back on the
/// back-channel and hands it to the CLI without reading it. This one is
/// different. The daemon maps it onto the same numeric refusal its own
/// scope check produces, so an agent has one number to branch on
/// whichever layer refused, and that means both sides must agree on the
/// string. Defined once here rather than written as a literal at the two
/// call sites.
public enum IntentErrorCode {
    /// A per-target workspace mutation refused because the caller lacks
    /// the required authority over the resolved target and holds no live
    /// automation grant. Raised GUI-side after ref resolution, since only
    /// the GUI knows which tab a ref names.
    public static let automationRequired = "intent.automationRequired"
}

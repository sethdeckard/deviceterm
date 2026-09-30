// SPDX-License-Identifier: GPL-3.0-or-later

/// Numeric RPC error codes the GUI and CLI act on by value.
///
/// Defined here rather than in the daemon so a client matches the number the
/// daemon sends instead of re-typing it, and never has to read the message to
/// tell one failure from another.
public enum DaemonErrorCode {
    /// A simulator attach refused because the simulator was read as shut down
    /// or shutting down. A client can offer to boot it; retrying the attach
    /// cannot succeed until it has booted.
    public static let deviceNotBooted = -32_021
}

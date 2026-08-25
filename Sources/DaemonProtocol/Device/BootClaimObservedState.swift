// SPDX-License-Identifier: GPL-3.0-or-later
//
// BootClaimObservedState: the strongest simulator state evidence carried by
// a pending boot claim.

public enum BootClaimObservedState: String, Codable, Sendable, Equatable {
    /// The validated GUI asked the daemon to begin the boot.
    case requested
    /// The shim's post-command snapshot observed CoreSimulator in Booting.
    case booting
    /// The shim's post-command snapshot already observed Booted.
    case booted
}

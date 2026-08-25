// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for `device.restoreOwnership`.
///
/// The simulator counterpart to `session.restoreBatch`, and for the same
/// reason: a fresh daemon starts holding NOTHING, and the one authority for
/// what deviceterm owns is the live, signature-validated GUI. Sessions come
/// back through `session.restoreBatch`; the sims those sessions booted come
/// back through this.
///
/// A sim carried by a pane is restored by re-attaching the pane, which
/// records ownership on its way through. A sim the user detached has no pane
/// to carry it, so without this call a replacement daemon cannot tell it from
/// a sim somebody else booted: it drops out of `device.list({scope:
/// "owned"})`, out of the menu bar's running-sim count, and out of the
/// tab-close and quit shut-down prompts, and only the next cold start
/// re-offers it through the orphan prompt.
///
/// `.validatedGUI`-scoped: the caller's audit token, validated against the
/// daemon's own signature, is the authority. Ownership attribution is exactly
/// what a UDS caller must not be able to assert on another session's behalf,
/// and the GUI is the only peer that legitimately spans sessions.
///
/// Additive, unlike `session.restoreBatch`. This is not a complete inventory
/// and never reaps: a udid the batch omits keeps whatever the daemon already
/// knows about it, and a udid the daemon ALREADY attributes keeps its live
/// attribution rather than being overwritten. The daemon's own knowledge is
/// newer than the GUI's mirror by construction, so re-assertion fills gaps
/// and never argues.
public struct DeviceRestoreOwnershipParams: Codable, Sendable, Equatable {
    /// The ownership claims to restore. Each may omit session attribution.
    /// Order is not significant; an empty array is valid and restores
    /// nothing.
    public let devices: [RestoredSimOwnership]

    public init(devices: [RestoredSimOwnership]) {
        self.devices = devices
    }
}

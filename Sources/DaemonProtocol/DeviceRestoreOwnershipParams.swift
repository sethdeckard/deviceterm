// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceRestoreOwnershipParams: wire shape for `device.restoreOwnership`.
//
// The simulator counterpart to `session.restoreBatch`, and for the same
// reason: a fresh daemon starts holding NOTHING, and the one authority for
// what deviceterm owns is the live, signature-validated GUI. Sessions come
// back through `session.restoreBatch`; the sims those sessions booted come
// back through this.
//
// A sim carried by a pane is restored by re-attaching the pane, which
// records ownership on its way through. A sim the user detached has no pane
// to carry it, so without this call a replacement daemon cannot tell it from
// a sim somebody else booted: it drops out of `device.list({scope:
// "owned"})`, out of the menu bar's running-sim count, and out of the
// tab-close and quit shut-down prompts, and only the next cold start
// re-offers it through the orphan prompt.
//
// `.validatedGUI`-scoped: the caller's audit token, validated against the
// daemon's own signature, is the authority. Ownership attribution is exactly
// what a UDS caller must not be able to assert on another session's behalf,
// and the GUI is the only peer that legitimately spans sessions.
//
// Additive, unlike `session.restoreBatch`. This is not a complete inventory
// and never reaps: a udid the batch omits keeps whatever the daemon already
// knows about it, and a udid the daemon ALREADY attributes keeps its live
// attribution rather than being overwritten. The daemon's own knowledge is
// newer than the GUI's mirror by construction, so re-assertion fills gaps
// and never argues.

public struct DeviceRestoreOwnershipParams: Codable, Sendable, Equatable {
    /// The ownership claims to restore. Each may omit session attribution.
    /// Order is not significant; an empty array is valid and restores
    /// nothing.
    public let devices: [RestoredSimOwnership]

    public init(devices: [RestoredSimOwnership]) {
        self.devices = devices
    }
}

/// One simulator in a restore batch, with its optional session attribution.
/// A malformed or duplicated entry rejects the whole batch with
/// `invalidParams`.
///
/// Deliberately absent:
/// - **cap**: the `.validatedGUI` scope is the authority, so no bearer
///   credential rides on the wire. The daemon keeps the ownership claim and
///   drops an attribution it cannot confirm live.
/// - **booted state**: the GUI's mirror can only say what was true when it
///   was last read. Whether the sim is still Booted is a live CoreSimulator
///   question the daemon answers for itself.
public struct RestoredSimOwnership: Codable, Sendable, Equatable {
    /// The simulator's UDID. Must parse as a UUID.
    public let udid: String
    /// The optional session attribution: the UUID string of the session it is
    /// attributed to, as restored by `session.restoreBatch`, or null for a sim
    /// deviceterm owns with nothing left to attribute it to.
    ///
    /// Null is not "unowned". It is the state a tab closed with Detach leaves
    /// behind: the session is gone, the sim keeps running, and it stays
    /// deviceterm's, listed under "Unlinked" in the status item and still
    /// offered at quit. Absent a conflicting attribution the daemon already
    /// holds, naming a session that has since closed reaches the same place,
    /// because the daemon demotes one it cannot confirm rather than refusing
    /// the claim.
    public let sessionId: String?

    public init(udid: String, sessionId: String?) {
        self.udid = udid
        self.sessionId = sessionId
    }
}

/// Reply to `device.restoreOwnership`: the ownership claims the daemon
/// accepted, lowercased and sorted.
///
/// A claim is absent when the daemon could not take it, which is not an error:
/// the simulator is not Booted, or the daemon already holds a conflicting
/// attribution for it. An otherwise admissible claim naming a session that is
/// no longer live IS present, restored without attribution. The caller learns
/// what stuck rather than being told the batch failed.
public struct DeviceRestoreOwnershipResult: Codable, Sendable, Equatable {
    public let restoredCount: Int
    public let udids: [String]

    public init(restoredCount: Int, udids: [String]) {
        self.restoredCount = restoredCount
        self.udids = udids
    }
}

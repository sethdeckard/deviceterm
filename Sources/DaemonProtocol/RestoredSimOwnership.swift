// SPDX-License-Identifier: GPL-3.0-or-later

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

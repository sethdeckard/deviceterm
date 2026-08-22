// SPDX-License-Identifier: GPL-3.0-or-later

import Daemon
import Foundation

#if canImport(Darwin)
import Darwin
#endif

public extension SessionManager {
    /// Test fixture: mint a session and return just its `SessionState`,
    /// discarding the one-time bearer capability. For the many tests that
    /// only need the session's identity/role and never authenticate a
    /// connection as it. Tests that DO need the capability call
    /// `createSession` and read `created.capability`.
    func makeSessionState(
        label: String? = nil,
        name: String? = nil,
        role: SessionRole = .agent,
        ownerPID: pid_t? = nil,
        initialProtected: Bool = false
    ) async throws -> SessionState {
        // Liveness/orphan tests pin a specific owner pid; the daemon derives
        // `ownerPID` from the captured owner identity, so wrap the test pid in
        // an `OwnerProcessIdentity` (the version/euid are irrelevant to the
        // `isAlive` pid ping these callers exercise).
        let owner = ownerPID.map {
            OwnerProcessIdentity(pid: $0, pidVersion: 0, euid: geteuid())
        }
        return try await createSession(
            label: label,
            name: name,
            role: role,
            owner: owner,
            initialProtected: initialProtected
        ).state
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The result of minting a session: the in-memory `state` (which holds only
/// a non-recoverable `CapabilityVerifier`) plus the one-time bearer
/// `capability`. The plaintext is returned here and **only** here. The
/// caller hands it to the client in the `session.create` response and keeps
/// no copy; the daemon retains just the verifier on the `state`.
public struct CreatedSession: Sendable {
    public let state: SessionState
    public let capability: Capability

    public init(state: SessionState, capability: Capability) {
        self.state = state
        self.capability = capability
    }
}

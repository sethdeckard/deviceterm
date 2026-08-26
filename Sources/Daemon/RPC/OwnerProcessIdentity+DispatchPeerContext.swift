// SPDX-License-Identifier: GPL-3.0-or-later

import TerminalProvenance

/// Daemon-only mapping from a dispatch transport to the shared owner
/// identity.
public extension OwnerProcessIdentity {
    /// Derive the owner identity from the transport facts captured by the
    /// daemon. This stays here because `DispatchPeerContext` is daemon-owned.
    static func from(_ context: DispatchPeerContext) -> OwnerProcessIdentity? {
        switch context.transport {
        case .xpc:
            #if canImport(Darwin)
            return context.auditToken.map(OwnerProcessIdentity.init(auditToken:))
            #else
            return nil
            #endif

        case .uds:
            return context.peerProcess.map(OwnerProcessIdentity.init)
        }
    }
}

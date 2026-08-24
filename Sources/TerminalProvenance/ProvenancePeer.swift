// SPDX-License-Identifier: GPL-3.0-or-later
//
// ProvenancePeer: the caller's kernel identity, shaped per transport.
//
// The transport decides which provenance arms are even available, so the
// identity carries the transport in its shape rather than as a side flag.
// `ProvenanceMatcher` consumes it.

import Foundation

/// The caller's kernel identity, shaped per transport. `.missing` is the
/// fail-closed case (the kernel couldn't vend an identity).
public enum ProvenancePeer: Sendable, Equatable {
    /// XPC peer whose audit token passed the daemon's signature check.
    case validatedGUI(owner: OwnerProcessIdentity)
    /// XPC peer that did NOT validate as the GUI. Owner arm only; no terminal
    /// arm on XPC (terminal callers use UDS).
    case xpc(owner: OwnerProcessIdentity)
    /// UDS peer with full kernel identity, plus the verified ancestor prefix
    /// above it. Owner, terminal, and anchored-ancestry arms.
    ///
    /// The prefix rides in the `.uds` payload rather than as a separate
    /// parameter because it exists only on this transport: XPC has no terminal
    /// arm, so an XPC peer has no use for ancestors and cannot be handed any.
    case uds(PeerProcessIdentity, ancestors: [AncestorProcessIdentity])
    /// The kernel could not vend a peer identity. Fail closed.
    case missing
}

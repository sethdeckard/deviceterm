// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// A non-recoverable verifier for a session `Capability`.
///
/// The daemon stores this in place of the bearer token so no recoverable
/// credential is retained in memory: it holds only a hash, never a usable
/// capability. It is a domain-separated SHA-256 over the capability's raw
/// bytes (`SHA-256("deviceterm.session.capability.v1" || bytes)`) and is
/// always exactly 32 bytes. The daemon persists nothing to disk, so there is
/// no at-rest copy at all; on a restart the validated GUI re-supplies the
/// bearer cap (`session.restoreBatch`) and the daemon re-derives this verifier.
///
/// **Scope of the guarantee (narrow, deliberately).** `SessionManager` retains
/// no recoverable plaintext after a session is created. The plaintext
/// capability still exists *transiently*: in the `session.create` response,
/// in transport buffers, in GUI state, and in the tab's environment. This type
/// is NOT a claim that the token is secret. In particular a same-uid process
/// CAN read another tab's environment (`ps -E`), so the cap alone can't
/// authenticate a session: the daemon pairs it with kernel peer/terminal
/// provenance (see `ProvenanceMatcher`). Possession is one factor, not proof
/// of tab membership.
///
/// **A verifier is not a capability.** The two are distinct types and a
/// serialized verifier can never be handed to the RPC layer where a
/// `Capability` is expected. Even if its 32 bytes were presented as a bearer
/// cap, `matches` re-hashes the presentation, which cannot equal the stored
/// verifier, so the serialized verifier authenticates as nothing.
public struct CapabilityVerifier: Sendable, Hashable {
    /// Domain-separation prefix, versioned so a future scheme change is
    /// unambiguous and can't collide with this one.
    private static let domain = Data("deviceterm.session.capability.v1".utf8)

    /// SHA-256 digest length. A verifier is always exactly this wide.
    public static let byteCount = 32

    /// The 32-byte digest.
    public let bytes: Data

    /// Derive the verifier for a plaintext capability.
    public init(for capability: Capability) {
        var hasher = SHA256()
        hasher.update(data: Self.domain)
        hasher.update(data: capability.bytes)
        self.bytes = Data(hasher.finalize())
    }

    /// Constant-time check that `capability` derives this verifier. The
    /// comparison runs over the full 32 bytes regardless of where a mismatch
    /// first appears, so it leaks no information through timing.
    public func matches(_ capability: Capability) -> Bool {
        let candidate = CapabilityVerifier(for: capability).bytes
        guard candidate.count == bytes.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(candidate, bytes) { difference |= lhs ^ rhs }
        return difference == 0
    }
}

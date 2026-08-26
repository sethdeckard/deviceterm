// SPDX-License-Identifier: GPL-3.0-or-later

/// One reusable implementation of validated-GUI issuer
/// retirement, for a store whose entries are owned by a GUI connection.
///
/// A store may key its entries to the id of the validated-GUI XPC connection
/// that issued them. When that connection closes, its entries must be revoked
/// AND any of its requests still in flight (one that suspended before the close
/// and resumes after) must be rejected. `AutomationGrantStore` embeds this
/// type, and any other store with GUI-issued entries can reuse it rather
/// than hand-rolling the closed-issuer logic and letting it drift.
///
/// It is a value type on purpose. Consulted under the embedding store's own
/// actor isolation, a store checks retirement and applies its mutation in a
/// SINGLE actor turn with no suspension between them. A shared *actor* could
/// not give that: consulting a separate actor forces an `await`, reopening a
/// window between the retirement check and the apply.
///
/// `XPCConnection.close()` is the authoritative close event: it calls the
/// store's `revokeAll(issuedBy:)`, which retires the id in its embedded
/// lifecycle in the same turn it revokes that connection's entries.
///
/// Retirement is monotonic: once retired, an id stays retired for the
/// daemon's lifetime. Not persisted; a daemon restart starts empty, and
/// restored sessions carry no issuer-owned authority to begin with.
struct IssuerLifecycle: Sendable {
    private var retired: Set<UInt64> = []

    /// Retire a connection id. Idempotent. Called in the same actor turn as
    /// the embedding store revokes that connection's entries.
    mutating func retire(_ connectionId: UInt64) {
        retired.insert(connectionId)
    }

    /// Whether `connectionId` has been retired. The embedding store checks
    /// this synchronously in its apply path (the grant store, in `grant`),
    /// so a request from a since-closed connection is rejected atomically.
    func isRetired(_ connectionId: UInt64) -> Bool {
        retired.contains(connectionId)
    }
}

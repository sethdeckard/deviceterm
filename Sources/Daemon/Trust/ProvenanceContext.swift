// SPDX-License-Identifier: GPL-3.0-or-later
//
// ProvenanceContext: the single source of the terminal-anchor store and the
// per-request provenance lookup, so the store the `session.bindTerminal`
// handler binds into, the store the lookup reads, and the store the XPC close
// path revokes are the SAME instance: structurally, not by convention.
//
// The store is NOT a free parameter: a context can only be built from a
// `SessionManager`, and `anchorStore` is a computed passthrough to that
// manager's own store. There is deliberately no initializer that accepts an
// arbitrary store, so a caller cannot wire a lookup that reads store A while
// the close path revokes store B. `defaultRegistry` derives the bindTerminal
// store from the SAME `sessionManager`, so binding and provenance can't
// diverge as long as one manager backs both (which `main.swift` and the test
// harnesses guarantee by passing one manager).
//
// `lookupOverride` exists ONLY for tests that need a synthetic snapshot
// function (e.g. an owner-arm match for an in-process XPC peer); it substitutes
// the lookup WITHOUT decoupling the store from the manager.

import Foundation

public struct ProvenanceContext: Sendable {
    /// The manager whose store + sessions this context reflects.
    public let sessionManager: SessionManager
    /// Per-request provenance snapshot lookup, reading `sessionManager`'s store.
    public let lookup: SessionProvenanceLookup

    /// The shared anchor store: always the manager's own, never arbitrary.
    public var anchorStore: TerminalAnchorStore { sessionManager.terminalAnchorStore }

    /// The restoration-barrier gate, derived from the same manager: returns
    /// true once the manager's restoration barrier is released. The connection
    /// layer reads this in `session.authenticate` so an unknown session is
    /// retryable (`notReady`) while a fresh daemon still awaits its restore
    /// batch, and terminal (`unauthorized`) afterward. Bundled on the context
    /// (rather than passed separately) for the same reason the anchor store is:
    /// the gate the connection reads and the barrier `restoreBatch` releases
    /// are the same manager by construction.
    public var restorationComplete: @Sendable () async -> Bool {
        let manager = sessionManager
        return { await manager.isRestorationComplete }
    }

    /// Production initializer: the lookup is DERIVED from the manager's store:
    /// there is no way to substitute an arbitrary one, so binding, lookup, and
    /// revocation are the same store by construction.
    public init(sessionManager: SessionManager) {
        self.init(sessionManager: sessionManager, lookupOverride: nil)
    }

    /// Test-only SPI: substitute a synthetic lookup (e.g. an owner-arm match
    /// for an in-process XPC peer) WITHOUT decoupling the store from the
    /// manager. Reachable only from `@_spi(ProvenanceTesting) import Daemon`,
    /// so production can't wire a lookup that reads a different store.
    @_spi(ProvenanceTesting)
    public init(sessionManager: SessionManager, lookupOverride: SessionProvenanceLookup?) {
        self.sessionManager = sessionManager
        let store = sessionManager.terminalAnchorStore
        self.lookup = lookupOverride ?? { sessionId in
            // Read the admission phase AND the captured owner atomically (one
            // actor turn), so the incarnation and the owner can't straddle a
            // G→G+1 transition. A `.notReady` id (mid-registration or
            // mid-teardown) is retryable even though its owner/anchor may still
            // be readable; a torn-down id whose session map entry is already
            // gone still reports `.notReady` across the teardown tail; `.absent`
            // is the terminal "gone".
            let snapshot = await sessionManager.provenanceSnapshot(for: sessionId)
            switch snapshot.admission {
            case .absent:
                return nil

            case .notReady:
                return SessionProvenanceSnapshot(owner: nil, anchor: nil, admission: .notReady)

            case let .ready(incarnation):
                // The anchor lives in a separate actor, so read it, then
                // re-confirm the incarnation is unchanged: if a transition
                // landed under the anchor read, the anchor might belong to a
                // different incarnation, so report `.notReady` (retryable)
                // rather than pair a stale anchor with this incarnation.
                let anchor = await store.anchor(for: sessionId)
                guard case .ready(incarnation) = await sessionManager.admission(for: sessionId) else {
                    return SessionProvenanceSnapshot(owner: nil, anchor: nil, admission: .notReady)
                }
                return SessionProvenanceSnapshot(
                    owner: snapshot.owner,
                    anchor: anchor,
                    admission: .ready(incarnation: incarnation)
                )
            }
        }
    }
}

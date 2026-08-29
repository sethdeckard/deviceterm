// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

public struct SessionState: Sendable, Equatable {
    public let id: UUID
    /// Stable grouping/reference UUID. Sessions in one GUI tab share it; a
    /// session created without a tab UUID uses `id`.
    public let tabId: UUID
    /// Non-recoverable verifier for this session's capability. The daemon
    /// stores this rather than the bearer token so in-memory state can't be
    /// replayed and no credential is ever written to disk; `validate`
    /// re-derives the verifier from a presented capability and compares. The
    /// plaintext capability is returned once at create time (`CreatedSession`)
    /// and never held here. On a daemon restart the validated GUI re-supplies
    /// the bearer cap via `restoreBatch` and the daemon re-derives this.
    public let capabilityVerifier: CapabilityVerifier
    /// Crockford base32 short_id (lowercased, 6 chars). Daemon-minted
    /// at create time via `ShortID.generate(...)` with collision retry
    /// against the live session set. Immutable for the session's
    /// lifetime so an agent printing `deviceterm tabs current` after a
    /// rename doesn't see the handle move.
    public let shortId: String
    public let label: String?
    /// Optional name, taken from the `session.create` request and
    /// never rewritten (`deviceterm tab rename` retitles the tab in
    /// the GUI without touching this). `nil` when the request carried
    /// none. Distinct from `label`, which is the internal
    /// classification (default `nil`; debugging surfaces use it).
    /// Visible on `tabs.list` rows.
    public let name: String?
    /// Role the daemon assigned at create time (descriptive metadata, not
    /// an authorization gate). Defaults to
    /// `.agent` when `session.create` omits the field. Immutable for
    /// the session's lifetime. The GUI's "Open Automation Tab"
    /// menu is the intended product-UI path for minting a fresh
    /// `.automation` session (no CLI verb emits the request).
    /// The daemon enforces that: an automation mint is refused
    /// outright over UDS, and over XPC only after the peer's audit
    /// token validates against the daemon's own signature.
    public let role: SessionRole
    /// Process id of the process that minted this session, for orphan
    /// recovery (`SessionManager.isAlive`'s `kill(pid, 0)` liveness ping; also
    /// mirrored to the session dir's `owner.pid` marker cold-start recovery
    /// reads). Derived server-side from `owner` (`owner?.pid`), not a
    /// caller-supplied wire field, so a caller can't name a pid it doesn't
    /// own. Nil only for a session the daemon couldn't attribute to a live
    /// peer (a test/tooling constructor); `isAlive` treats nil as "assume
    /// alive". A session restored via `restoreBatch` captures the live GUI as
    /// its owner, so it is NOT nil. It drives orphan recovery, not authority.
    public let ownerPID: pid_t?
    /// Kernel identity of the process that created this session, captured
    /// server-side from the transport peer at `session.create` (the audit
    /// token on XPC or the `LOCAL_PEERTOKEN` identity on UDS), never from a
    /// caller-supplied field. It is the "exact owner" provenance arm: the
    /// creating process (the GUI, including its UDS smoke fallback)
    /// authenticates as this session without a terminal anchor. Matched on
    /// `(pid, pidVersion, euid)`.
    ///
    /// Nil only for a session the daemon can't attribute to a live peer (a
    /// test/tooling constructor that omits it). A session restored via
    /// `restoreBatch` captures the validated GUI's identity as its owner
    /// (identical to `session.create` over XPC), so the exact-owner arm
    /// authenticates it and `isAlive` tracks the GUI. A nil owner simply means
    /// the owner arm never matches; the terminal and validated-GUI arms still
    /// authorize.
    public let owner: OwnerProcessIdentity?
    public let createdAt: Date

    public init(
        id: UUID,
        capabilityVerifier: CapabilityVerifier,
        shortId: String,
        label: String?,
        name: String?,
        createdAt: Date,
        role: SessionRole = .agent,
        ownerPID: pid_t? = nil,
        owner: OwnerProcessIdentity? = nil,
        tabId: UUID? = nil
    ) {
        self.id = id
        self.tabId = tabId ?? id
        self.capabilityVerifier = capabilityVerifier
        self.shortId = shortId
        self.label = label
        self.name = name
        self.role = role
        self.ownerPID = ownerPID
        self.owner = owner
        self.createdAt = createdAt
    }
}

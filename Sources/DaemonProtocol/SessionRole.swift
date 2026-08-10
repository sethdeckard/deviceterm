// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionRole: the role a daemon session was minted with. Descriptive
// metadata, not an authorization gate; only its *minting* is trust-gated.
//
// Two values, immutable for the session's lifetime. The wire
// protocol intentionally has no `session.update_role` primitive
// because role-mutation is a trust hand-off the agent must not be
// able to perform via a CLI verb. Plain CLI invocations never carry
// `--role`; the GUI's "Open Orchestrator Tab" menu is the *intended*
// way to mint `.orchestrator`, and the daemon enforces that rather
// than assuming it: `session.create` refuses an orchestrator role
// outright over UDS, and over XPC accepts one only after the peer's
// audit token validates against the daemon's own code signature.
// Constructing the raw JSON-RPC frame by hand does not get around
// it: the CLI's transport can't reach the role at all.
//
// Carried on `session.create` requests (optional, defaults to
// `.agent` at the daemon) and on `session.create` responses (always
// emitted). Older clients that don't decode the field ignore it
// (Codable's synthesized init drops unknown keys).
//
// Descriptive metadata, NOT an authorization gate. Orchestrator-scoped
// methods are authorized by a live orchestration grant (see
// `OrchestratorGrantStore`), not by this role: a granted `.agent`
// reaches them and an ungranted `.orchestrator` does not. The role rides
// `tabs.list` and `session.create` responses for display/diagnostics.

public enum SessionRole: String, Codable, Sendable, Equatable, CaseIterable {
    /// Default. Read/write on its own linked panes only; cross-session
    /// *pane* access is never conferred by a grant. The cross-tab *terminal*
    /// verbs (`tab send-input`/`capture`) are a separate axis, gated by a
    /// live orchestration grant, not by this role, so a *granted* agent
    /// reaches them and an ungranted one does not.
    case agent

    /// The GUI mints this for a human-opened orchestrator tab. Descriptive
    /// metadata, NOT the authorization gate: cross-tab send-input/capture is
    /// authorized by a live orchestration grant (see `OrchestratorGrantStore`),
    /// never by this role: a granted `.agent` reaches those verbs and an
    /// ungranted `.orchestrator` does not. Role escalation, pane linking, and
    /// privacy toggles are human-only via the GUI for both roles; both roles
    /// can spawn with `--cmd`.
    case orchestrator
}

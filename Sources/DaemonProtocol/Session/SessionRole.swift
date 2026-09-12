// SPDX-License-Identifier: GPL-3.0-or-later

/// The role a daemon session was minted with. Descriptive
/// metadata, not an authorization gate; only its *minting* is trust-gated.
///
/// Two values, immutable for the session's lifetime. The wire
/// protocol intentionally has no `session.update_role` primitive
/// because role-mutation is a trust hand-off the agent must not be
/// able to perform via a CLI verb. Plain CLI invocations never carry
/// `--role`; the GUI's "Open Automation Tab" menu is the *intended*
/// way to mint `.automation`, and the daemon enforces that rather
/// than assuming it: `session.create` refuses an automation role
/// outright over UDS, and over XPC accepts one only after the peer's
/// audit token validates against the daemon's own code signature.
/// Constructing the raw JSON-RPC frame by hand does not get around
/// it: the CLI's transport can't reach the role at all.
///
/// Carried on `session.create` requests (optional, defaults to
/// `.agent` at the daemon) and on `session.create` responses (always
/// emitted). Older clients that don't decode the field ignore it
/// (Codable's synthesized init drops unknown keys).
///
/// Automation-scoped methods require a live automation grant (see
/// `AutomationGrantStore`): a granted `.agent` reaches them and an
/// ungranted `.automation` does not. The role rides session creation and
/// restoration wire shapes for diagnostics and state reconstruction.
public enum SessionRole: String, Codable, Sendable, Equatable, CaseIterable {
    /// Default descriptive role. It grants no authority by itself. A live
    /// automation grant can authorize workspace focus and movement, mutations
    /// of visible foreign targets, and terminal input or capture.
    case agent

    /// The GUI mints this for a human-opened automation tab. Descriptive
    /// metadata, not the authorization gate. An ungranted automation session
    /// has the same authority as an ungranted agent session. Grants can widen
    /// authority over visible foreign tabs; daemon-direct device-pane methods
    /// remain constrained by their cohort checks. Role escalation is
    /// human-only, and both roles can spawn with `--command`.
    case automation
}

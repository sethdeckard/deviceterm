// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A daemon-to-GUI back-channel request.
///
/// The wire envelope: `params` is the kind-specific Codable struct,
/// JSON-encoded on the daemon side and JSON-decoded on the GUI side
/// once the kind is read.
///
/// The CLI's `deviceterm tab close --tab <ref>` (and the other
/// workspace verbs) hits the daemon over the existing UDS RPC. For ops
/// the daemon can't perform on its own (anything that mutates GUI tab /
/// pane / window state), the daemon constructs an `AppCommand` and
/// publishes it on the dedicated `app.commands` subscription that
/// the GUI maintains at startup. The GUI translates the command into
/// a `RouteIntent`, dispatches via `IntentDispatcher`, and acks the
/// result via `app.commandResult`. The daemon correlates by
/// `commandId` and resumes the original handler's continuation so
/// the CLI caller gets a synchronous-feeling answer.
///
/// Wire shape: a flat struct with a `kind` discriminator and a JSON
/// `params` blob. Strong-typed per-kind params live in
/// `AppCommandParams.<Kind>` sub-types; the GUI decodes the discriminator
/// first, then the matching sub-type.
///
/// `AppCommandKind` is a closed enum and decodes strictly, so a `kind` the
/// GUI does not know fails to decode the whole frame. The subscriber logs
/// it and drops it without acking, which leaves the daemon's caller waiting
/// on its reply deadline. Adding a kind is a coordinated change across the
/// daemon and the GUI, not a one-sided one.
public struct AppCommand: Codable, Sendable, Equatable {
    /// Correlation id the daemon stamps into the published command
    /// and the GUI echoes back in `app.commandResult`. The daemon's
    /// AppCommandCoordinator keys its pending continuations by this.
    public let commandId: String

    /// What the GUI should do. See `AppCommandKind`.
    public let kind: AppCommandKind

    /// Caller's session id when the request came in over an
    /// authenticated UDS connection (CLI inside a tab). `nil` for
    /// daemon-wide callers, including an out-of-tab `windowsList --all`
    /// request (a stock-terminal CLI that can't invoke session-scoped
    /// verbs). The GUI builds the intent's
    /// `IntentOrigin.external(sessionID:hasAutomationGrant:)` from this,
    /// so `--tab current` / `--pane current` mean "the calling tab's
    /// tab/pane" and a foreign protected tab stays opaque to the caller.
    public let originatingSessionId: String?

    /// Whether the originating session held a live automation grant when
    /// the daemon accepted the request. Read from the
    /// `AutomationGrantStore` at publish time, never from caller-supplied
    /// request data and never from a role, so a CLI caller cannot assert
    /// it. The GUI gates
    /// the cross-tab verbs on it: without one, a caller reaches only tabs
    /// it owns a terminal in.
    ///
    /// The grant widens authority, never visibility. A foreign protected
    /// tab stays `notFound` with or without it.
    public let originAutomationGrant: Bool

    /// Kind-specific params, encoded as a JSON object. The GUI side
    /// decodes into `AppCommandParams.<Kind>` after reading `kind`.
    public let params: Data

    /// Monotonic instant (`AppCommandDeadline.nowMonotonicNanos`) past
    /// which the GUI must decline this command instead of performing it.
    ///
    /// Both hops buffer unbounded, so an `AppCommand` can remain queued
    /// past its reply deadline and would otherwise run whenever the
    /// drain loop next moves, potentially after the caller has already
    /// received an error. The daemon cannot unsend a buffered frame, so
    /// the consumer declines it.
    ///
    /// `nil` means no expiry, which is how a frame from a daemon that
    /// predates this field decodes. That direction fails open on
    /// purpose: an older daemon's commands behave exactly as they did
    /// before rather than being dropped wholesale by a newer GUI.
    public let expiresAtMonotonicNanos: UInt64?

    public init(
        commandId: String,
        kind: AppCommandKind,
        originatingSessionId: String?,
        params: Data,
        originAutomationGrant: Bool = false,
        expiresAtMonotonicNanos: UInt64? = nil
    ) {
        self.commandId = commandId
        self.kind = kind
        self.originatingSessionId = originatingSessionId
        self.originAutomationGrant = originAutomationGrant
        self.params = params
        self.expiresAtMonotonicNanos = expiresAtMonotonicNanos
    }

    // Decode an absent `originAutomationGrant` as false, so incomplete
    // input fails closed: the cost is a refusal a legitimate caller can
    // retry, where the opposite default would hand an ungranted caller
    // cross-tab authority. Encoding stays synthesized.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try container.decode(String.self, forKey: .commandId)
        kind = try container.decode(AppCommandKind.self, forKey: .kind)
        originatingSessionId = try container.decodeIfPresent(
            String.self,
            forKey: .originatingSessionId
        )
        originAutomationGrant = try container.decodeIfPresent(
            Bool.self,
            forKey: .originAutomationGrant
        ) ?? false
        params = try container.decode(Data.self, forKey: .params)
        // Absent means "no expiry", unlike `originAutomationGrant`
        // above, which fails closed. Opposite defaults, opposite risks:
        // an absent grant that defaulted true would hand out authority,
        // where an absent expiry that defaulted to "already expired"
        // would silently discard every command from an older daemon.
        expiresAtMonotonicNanos = try container.decodeIfPresent(
            UInt64.self,
            forKey: .expiresAtMonotonicNanos
        )
    }

    /// Whether this command's deadline has passed as of `now`.
    ///
    /// An unstamped command never expires; see
    /// `expiresAtMonotonicNanos`.
    public func hasExpired(
        asOf now: UInt64 = AppCommandDeadline.nowMonotonicNanos()
    ) -> Bool {
        guard let deadline = expiresAtMonotonicNanos else { return false }
        return now >= deadline
    }
}

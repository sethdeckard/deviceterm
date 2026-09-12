// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A daemon-to-GUI back-channel request.
///
/// The wire envelope: `params` is the kind-specific Codable struct,
/// JSON-encoded on the daemon side and JSON-decoded on the GUI side
/// once the kind is read.
///
/// `deviceterm tab close <ref>` and the other GUI-backed workspace verbs hit
/// the daemon over UDS RPC. The daemon constructs an `AppCommand` and publishes
/// it on the dedicated `app.commands` subscription that the GUI maintains at
/// startup. The GUI translates the command into a `RouteIntent`, dispatches via
/// `IntentDispatcher`, and acknowledges the result via `app.commandResult`.
/// The daemon correlates by `commandId` and resumes the original handler's
/// continuation so the CLI caller gets a synchronous-feeling answer.
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

    /// Authenticated terminal-session id used to resolve omitted and `current`
    /// workspace references. The GUI builds
    /// `IntentOrigin.external(sessionID:hasAutomationGrant:)` from it, so
    /// current tab and pane references stay relative to the calling terminal.
    public let originatingSessionId: String?

    /// Whether the originating session held a live automation grant when
    /// the daemon accepted the request. Read from the
    /// `AutomationGrantStore` at publish time, never from caller-supplied
    /// request data and never from a role, so a CLI caller cannot assert it.
    /// A grant widens mutation, focus, and terminal-I/O authority. It does not
    /// govern read visibility: ungranted callers may read visible foreign tabs,
    /// while protected foreign tabs remain `notFound` with or without a grant.
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

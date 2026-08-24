// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppCommand: daemon-to-GUI back-channel request.
//
// The CLI's `deviceterm tab close --tab <ref>` (and the other
// workspace verbs) hits the daemon over the existing UDS RPC. For
// ops the
// daemon can't perform on its own (anything that mutates GUI tab /
// pane / window state), the daemon constructs an `AppCommand` and
// publishes it on the dedicated `app.commands` subscription that
// the GUI maintains at startup. The GUI translates the command into
// a `RouteIntent`, dispatches via `IntentDispatcher`, and acks the
// result via `app.commandResult`. The daemon correlates by
// `commandId` and resumes the original handler's continuation so
// the CLI caller gets a synchronous-feeling answer.
//
// Wire shape: a flat struct with a `kind` discriminator and a JSON
// `params` blob. Strong-typed per-kind params live in `AppCommand
// Params.<Kind>` sub-types; the GUI decodes the discriminator first,
// then the matching sub-type. New `kind` values can ship without a
// wire-version bump (newer GUI sees them; older one returns
// `unknownKind`).

import Foundation

/// The wire envelope. `params` is the kind-specific Codable struct,
/// JSON-encoded on the daemon side and JSON-decoded on the GUI side
/// once the kind is read.
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

    public init(
        commandId: String,
        kind: AppCommandKind,
        originatingSessionId: String?,
        params: Data,
        originAutomationGrant: Bool = false
    ) {
        self.commandId = commandId
        self.kind = kind
        self.originatingSessionId = originatingSessionId
        self.originAutomationGrant = originAutomationGrant
        self.params = params
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
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The typed error surface for `IntentDispatcher`.
///
/// Codes are stable strings so CLI receipts can carry them in JSON
/// mode without depending on Swift error type names. Each case
/// carries a `hint` that the CLI prints on stderr (human mode) or
/// includes in the JSON receipt (json mode); UI surfaces translate
/// it into a sheet body.
enum IntentError: Error, Sendable, Equatable {
    /// External ref didn't resolve to anything live. Carries the
    /// kind ("tab" / "pane" / "window") and the original ref text
    /// so the hint can echo what the caller typed.
    case notFound(
        kind:
        String,
        ref: String
        )

    /// External ref was ambiguous, e.g. `--tab feature` matched two
    /// tabs both named "feature".
    case ambiguous(
        kind:
        String,
        ref: String,
        matchCount: Int
        )

    /// The GUI didn't respond to a back-channel command within the
    /// timeout. Could mean the GUI is wedged, mid-launch, or no GUI
    /// process is subscribed. Distinct from `notFound` so CLI
    /// agents can retry only this one.
    case guiUnavailable(
        timeoutMs:
        Int
        )

    /// `closeTab` / `closeWindow` was cancelled by the user (e.g.
    /// they hit Cancel in the close-with-sims prompt). The Router
    /// already cancelled the route; the dispatcher just relays.
    case userCancelled

    /// The caller lacks authority over the resolved target and holds no
    /// live automation grant. Deliberately distinguishable from `notFound`,
    /// unlike the protection gate: resolution runs first, so a foreign
    /// protected tab is already `notFound` before this can fire.
    /// Anything that gets here is a tab the caller can already see in
    /// `tab list`, so naming the reason leaks nothing and a `notFound`
    /// would be a confusing lie. Carries the verb for the hint.
    case automationRequired(verb: String)

    /// Closing the final terminal pane would implicitly destroy the tab.
    /// The public CLI keeps that boundary explicit: callers must choose
    /// `tab close` when they intend to close the workspace.
    case wouldCloseTab

    /// The selected pane exists, but does not support the requested verb.
    case unsupportedPane(verb: String, kind: WorkspacePaneKind)

    /// A compound mutation committed a resource before a later operation
    /// failed. The committed receipt lets the caller address and clean up
    /// what now exists instead of rediscovering it by polling.
    case mutationFailed(message: String, committed: WorkspaceMutationReceipt)

    /// A pane attach failed before it committed a pane. When the failure came
    /// from the daemon, `forwardedRPCCode` lets the back-channel return that
    /// numeric RPC error unchanged instead of wrapping it as an intent-layer
    /// internal error. Caller-local failures use `rpc.serverError`.
    case attachFailed(message: String, forwardedRPCCode: Int)

    /// Internal invariant broken. Surfaces as a bug message
    /// pointing at the source-layer caller. Wraps an underlying
    /// description.
    case internalError(String)

    /// Stable wire code. Matches the CLI's `RPCErrorCode`-style
    /// strings agents key on.
    var code: String {
        switch self {
        case .notFound:
            return "intent.notFound"

        case .ambiguous:
            return "intent.ambiguous"

        case .guiUnavailable:
            return "intent.guiUnavailable"

        case .userCancelled:
            return "intent.userCancelled"

        case .automationRequired:
            // Shared with the daemon, which remaps this one code onto
            // its own numeric scope refusal; the rest it only relays.
            return IntentErrorCode.automationRequired

        case .wouldCloseTab:
            return "intent.wouldCloseTab"

        case .unsupportedPane:
            return "intent.unsupportedPane"

        case .mutationFailed:
            return "intent.mutationFailed"

        case .attachFailed:
            return "intent.attachFailed"

        case .internalError:
            return "intent.internalError"
        }
    }

    /// Human-readable hint. Carries enough detail for the CLI to
    /// print without further lookup.
    var hint: String {
        switch self {
        case let .notFound(kind, ref):
            return "\(kind) '\(ref)' not found"

        case let .ambiguous(kind, ref, matchCount):
            return "\(kind) ref '\(ref)' matched \(matchCount) entries; "
                + "use a unique short ID or the full ID"

        case let .guiUnavailable(timeoutMs):
            return "no GUI response within \(timeoutMs)ms; the "
                + "deviceterm app may be wedged or not running"

        case .userCancelled:
            return "cancelled by user"

        case let .automationRequired(verb):
            return "\(verb) needs a live automation grant for this "
                + "target; run it from an Automation Tab"

        case .wouldCloseTab:
            return "closing the last terminal pane would close its tab; "
                + "use `deviceterm tab close` instead"

        case let .unsupportedPane(verb, kind):
            return "pane \(verb) is not supported by a \(kind.rawValue) pane"

        case let .mutationFailed(message, _):
            return message

        case let .attachFailed(message, _):
            return message

        case let .internalError(description):
            return "internal: \(description)"
        }
    }

    /// JSON context copied through the back-channel and outer RPC error.
    var details: Data? {
        guard case let .mutationFailed(_, committed) = self,
            let encoded = try? JSONEncoder().encode(committed),
            let object = try? JSONSerialization.jsonObject(with: encoded),
            let data = try? JSONSerialization.data(
                withJSONObject: ["committed": object],
                options: [.sortedKeys]
            ) else { return nil }
        return data
    }

    /// Numeric daemon error to relay through the GUI back-channel unchanged.
    var forwardedRPCCode: Int? {
        guard case let .attachFailed(_, code) = self else { return nil }
        return code
    }
}

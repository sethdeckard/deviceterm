// SPDX-License-Identifier: GPL-3.0-or-later
//
// IntentError: the typed error surface for `IntentDispatcher`.
//
// Codes are stable strings so CLI receipts can carry them in JSON
// mode without depending on Swift error type names. Each case
// carries a `hint` that the CLI prints on stderr (human mode) or
// includes in the JSON receipt (json mode); UI surfaces translate
// it into a sheet body.

import Foundation

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
                + "use --short-id or the full UUID"

        case let .guiUnavailable(timeoutMs):
            return "no GUI response within \(timeoutMs)ms; the "
                + "deviceterm app may be wedged or not running"

        case .userCancelled:
            return "cancelled by user"

        case let .internalError(description):
            return "internal: \(description)"
        }
    }
}

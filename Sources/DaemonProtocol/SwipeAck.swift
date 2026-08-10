// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwipeAck: extended ack for `pane.input.swipe`. Surfaces the
// daemon's *dispatched* gesture kind so agents can detect when their
// requested swipe was silently promoted to a tap-shaped wire payload.
//
// Why this exists: `GestureTiming.steps` clamps to `max(1, clamped/16)`,
// so any caller requesting `durationMs < 32` gets `steps == 1` and the
// resulting wire is `tapDown(start) → tapDown(end) → tapUp(end)`,
// wire-indistinguishable from a tap. A caller that reads only
// `{"ok": true}` therefore cannot tell whether the drag it asked for
// dispatched as a drag or silently degraded to a tap, which matters to
// anything driving `deviceterm swipe` programmatically. SwipeAck
// surfaces the dispatch kind + the step count + the clamped duration
// the daemon actually used.
//
// Wire format adds three fields to the existing `{"ok": true}` shape:
//
//     {"ok": true, "dispatched": "tap"|"drag", "steps": N, "durationMs": M}
//
// Clients that only check `ok` continue to work unchanged. The wider
// "echo every resolved-target field on every input ack" pattern lives
// on the CLI side. SwipeAck stays swipe-specific; the broader
// response type will be a generalization, not a redesign.
//
// **Skew tolerance.** The three extension fields are `Optional` on the
// Swift side specifically so a newer CLI talking to an older daemon
// (the in-flight Sparkle-update / stranded-helper window where the
// helper is still on the prior version) sees `nil` instead of a
// decode error: the gesture still went through, the rich response
// just isn't available from that daemon. The new daemon always sends
// all three; the CLI prints the rich line iff every field is present
// and falls back to a bare `ok` otherwise. The stranded-helper
// recovery procedure (a future signing/notarization change) is
// still the right long-term answer; this just keeps single
// short-lived CLI invocations during the window from spuriously
// erroring.

import Foundation

/// The kind of gesture the daemon's HID dispatch actually produced
/// for an interpolated input. `tap` means the gesture collapsed to a
/// single down/up pair (the user's `durationMs` was below the one-
/// frame floor of `~32ms`); `drag` means multi-step interpolation
/// went out the door.
public enum SwipeDispatch: String, Codable, Sendable, Equatable {
    case tap
    case drag
}

public struct SwipeAck: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case success = "ok"
        case dispatched
        case steps
        case durationMs
    }

    public let success: Bool

    // Three extension fields. `Optional` to tolerate skew with an
    // older daemon that returns bare `{"ok": true}` for swipe (see
    // "Skew tolerance" in the file header). New daemons always set
    // all three; the CLI treats the triple atomically: rich output
    // iff every field is present, else bare `ok`. Partial-future /
    // partial-broken responses (only one or two fields present)
    // degrade to bare `ok` rather than turning an accepted gesture
    // into a CLI failure.

    public let dispatched: SwipeDispatch?
    public let steps: Int?

    /// The duration in milliseconds the daemon actually used, after
    /// clamping the caller's request to `[0, maxGestureDurationMs]`.
    /// Differs from the caller's `durationMs` when out-of-range.
    public let durationMs: Int?

    public init(steps: Int, durationMs: Int) {
        self.success = true
        self.steps = steps
        self.durationMs = durationMs
        self.dispatched = steps == 1 ? .tap : .drag
    }
}

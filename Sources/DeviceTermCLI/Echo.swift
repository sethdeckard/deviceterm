// SPDX-License-Identifier: GPL-3.0-or-later
//
// Echo: the `ok udid=… pane=… [key=value …]` line shape for every
// `pane.input.*` success.
//
// Each accepted input lands as a self-describing receipt rather than
// a bare `ok`. Agents who ran `deviceterm tap 0.5 0.5` would otherwise
// have had no signal that it landed on the intended sim until the
// next screenshot:
//
//   ok udid=<UDID> pane=<short_id> [per-command fields]
//
// The two leading columns are stable across every input command;
// the per-command fields slot in afterwards in a documented order.
// Swipe surfaces the `dispatched=`/`steps=`/`durationMs=` triple
// from `SwipeAck`, prepended with the udid/pane prefix, not
// replacing it.
//
// Pure namespace, no I/O, so it's testable without spawning a process.

import DaemonProtocol
import Foundation

public enum Echo {
    /// Format a successful-input echo line. Leading columns are
    /// `ok`, `udid=…`, `pane=…`; trailing key/value pairs are the
    /// per-command fields. Field order is the caller's
    /// responsibility, so agents parsing the line can rely on
    /// position (`awk '{print $3}'` for pane) or key match.
    public static func ok(
        udid: String,
        pane: String,
        fields: [(String, String)] = []
    ) -> String {
        var line = "ok udid=\(udid) pane=\(pane)"
        for (key, value) in fields {
            line += " \(key)=\(value)"
        }
        return line
    }

    /// Compose the per-command field list for a `swipe` ack. The
    /// daemon already ships `dispatched`/`steps`/`durationMs` on
    /// the wire; this helper just lays them out for the receipt
    /// line. When the daemon emits a bare `{ok:true}` (Sparkle
    /// skew), `ack.dispatched` is nil and the helper returns an
    /// empty field list: the receipt still carries the udid +
    /// pane prefix.
    public static func swipeFields(_ ack: SwipeAck) -> [(String, String)] {
        guard let dispatched = ack.dispatched,
            let steps = ack.steps,
            let durationMs = ack.durationMs else {
            return []
        }
        return [
            ("dispatched", dispatched.rawValue),
            ("steps", String(steps)),
            ("durationMs", String(durationMs))
        ]
    }
}

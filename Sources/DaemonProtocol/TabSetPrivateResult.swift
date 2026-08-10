// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabSetPrivateResult: the outcome of an *awaited* `tab set-private`.
//
// The GUI drives tab privacy as an asynchronous, fail-closed transition
// (hide immediately, converge the daemon via an idempotent batch). So the
// CLI reports the daemon's actual outcome rather than an optimistic echo:
//
//  - `committed == true`: the daemon confirmed the change; the state is
//    what the caller asked for.
//  - `committed == false`: the requested state is NOT yet confirmed and
//    the GUI may still be converging. It does not prove daemon
//    acceptance: pending may also mean the deadline expired, a same-state
//    request superseded it, or the tab disappeared before confirmation.
//
// A *definite* rejection (the daemon validated and refused) surfaces as an
// error result, not this payload.

public struct TabSetPrivateResult: Codable, Sendable, Equatable {
    public let isPrivate: Bool
    public let committed: Bool

    public init(isPrivate: Bool, committed: Bool) {
        self.isPrivate = isPrivate
        self.committed = committed
    }
}

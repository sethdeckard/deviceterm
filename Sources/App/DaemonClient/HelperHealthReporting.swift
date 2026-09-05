// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Role protocol: report the outcome of a call the caller bounded itself.
///
/// `DaemonClient` bounds nearly every request and feeds its own expiries to
/// the health accounting, so nothing has to tell it those. The exception is
/// the handful of calls that mint daemon state: they are exempt from the
/// client's bound because cancelling the transport would discard the reply
/// naming what was minted, and their caller raises the deadline instead. An
/// expiry there is the same evidence as any other, and without this it would
/// be the one kind the client never sees.
///
/// `generation` is the connection the call went to, sampled before sending.
/// An expiry that arrives after a reconnect is evidence about the peer that
/// went away, not the one that replaced it, so the client drops a report whose
/// generation has moved on.
@MainActor
protocol HelperHealthReporting: AnyObject {
    var connectionGeneration: Int { get }
    func noteCallerBoundedCallExpired(sentOn generation: Int)
}

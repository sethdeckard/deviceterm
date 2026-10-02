// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ServiceManagement

/// A repair that stopped part-way, carrying how far it got.
///
/// The stage matters because the two failures need opposite things said about
/// them. Failing before the unregister completes leaves the registration in an
/// unknown state, because the call may have mutated something before it threw.
/// Failing after it leaves the helper stopped and unregistered, which is the state that must not be described as
/// "couldn't stop the old helper": it stopped, and now nothing will start it.
struct RegistrationRepairFailure: Error, CustomStringConvertible {
    /// Whether the teardown leg completed before the failure.
    let unregistered: Bool
    /// Whether the teardown was attempted at all. False only when the repair
    /// stopped before calling `unregister()`, which touches nothing. Anything
    /// whose stage isn't known reads as attempted, the conservative answer.
    let teardownAttempted: Bool
    let underlying: any Error

    var description: String {
        if unregistered {
            return "the helper was unregistered but could not be registered again: \(underlying)"
        }
        if !teardownAttempted {
            return "the repair stopped before its teardown; the registration is unchanged: \(underlying)"
        }
        return "the unregister did not complete; the registration state is unknown: \(underlying)"
    }

    init(unregistered: Bool, underlying: any Error, teardownAttempted: Bool = true) {
        self.unregistered = unregistered
        self.underlying = underlying
        self.teardownAttempted = teardownAttempted
    }
}

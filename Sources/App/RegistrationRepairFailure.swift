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
    let underlying: any Error

    var description: String {
        unregistered
            ? "the helper was unregistered but could not be registered again: \(underlying)"
            : "the unregister did not complete; the registration state is unknown: \(underlying)"
    }
}

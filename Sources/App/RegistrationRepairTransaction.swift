// SPDX-License-Identifier: GPL-3.0-or-later
//
// RegistrationRepairTransaction: the order a launchd registration repair has to
// happen in, separated from the ServiceManagement calls that carry it out.
//
// The ordering IS the safety property, and it cannot be checked against the real
// `SMAppService`: those calls mutate the login session's launchd domain, so a
// test that ran them would reach outside the process and take the user's helper
// with it. Extracting the sequence behind injected legs is what makes it
// assertable at all.
//
// Three rules, each of which fails a different way if broken:
//
//   - Mark before tearing down. A teardown with no marker behind it can be
//     interrupted into a state nothing knows to finish, which leaves the user
//     with no helper.
//   - Clear only after standing back up, and never let a failed clear fail the
//     repair. The registration is whole at that point; a marker left behind
//     costs one redundant reconciliation.
//   - Report how far it got. Failing before the teardown completes leaves the
//     registration in an unknown state; failing after it leaves the helper
//     stopped and unstartable. Those need opposite things said about them, so
//     they cannot collapse into one error.

import Foundation

@MainActor
struct RegistrationRepairTransaction {
    /// Write the marker. A throw here aborts before anything is mutated.
    var markUnderway: @MainActor () throws -> Void
    /// Tear the registration down.
    var unregister: @MainActor () async throws -> Void
    /// Stand it back up.
    var register: @MainActor () throws -> Void
    /// Drop the marker. A throw here is deliberately swallowed.
    var clearUnderway: @MainActor () throws -> Void
    /// Whether an unregister failure means the teardown leg is already
    /// satisfied rather than that it failed. A job booted out from under a BTM
    /// record still reading enabled is one of the shapes a repair is called for.
    var isBenignUnregisterFailure: @MainActor (any Error) -> Bool

    /// Run the sequence, throwing `RegistrationRepairFailure` with the stage it
    /// reached.
    func run() async throws {
        do {
            try markUnderway()
        } catch {
            throw RegistrationRepairFailure(unregistered: false, underlying: error)
        }
        do {
            try await unregister()
        } catch {
            guard isBenignUnregisterFailure(error) else {
                throw RegistrationRepairFailure(unregistered: false, underlying: error)
            }
        }
        do {
            try register()
        } catch {
            throw RegistrationRepairFailure(unregistered: true, underlying: error)
        }
        // Not an error: the registration is whole, and the only cost of a marker
        // left behind is one redundant reconciliation on the next launch.
        try? clearUnderway()
    }
}

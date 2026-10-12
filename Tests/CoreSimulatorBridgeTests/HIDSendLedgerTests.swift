// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import Testing

// The ledger holds no SimulatorKit state, so these run on any host.

private func admit(_ ledger: SimHIDSendLedger, release: Bool = false) throws -> UInt64 {
    var ticket: UInt64 = 0
    try ledger.admitSend(asRelease: release, ticket: &ticket)
    return ticket
}

/// A settle handler registered now and read later. The ledger is an
/// Objective-C class Swift can't see is thread-safe, so the tests keep it on
/// one task and wait on the handler instead.
private final class SettleProbe: @unchecked Sendable {
    private let fired = DispatchSemaphore(value: 0)
    private var reported: NSError?

    /// Whether the handler has fired yet, without waiting for it.
    var hasFired: Bool {
        guard fired.wait(timeout: .now()) == .success else { return false }
        fired.signal()
        return true
    }

    init(_ ledger: SimHIDSendLedger) {
        ledger.whenSettled(on: DispatchQueue.global()) { error in
            self.reported = error as NSError?
            self.fired.signal()
        }
    }

    /// The handler's error, or nil with `didFire` false if it hasn't fired.
    func wait() -> (didFire: Bool, error: NSError?) {
        let didFire = fired.wait(timeout: .now() + 5) == .success
        return (didFire, reported)
    }
}

@Test
func sendsAreAdmittedWhileNothingIsOutstanding() throws {
    let ledger = SimHIDSendLedger()
    let first = try admit(ledger)
    ledger.complete(ticket: first, error: nil)
    _ = try admit(ledger)
    #expect(ledger.outstandingSendCount == 1)
}

@Test
func aSendIsRefusedBehindOneThatHasNotCompleted() throws {
    let ledger = SimHIDSendLedger()
    let stalled = try admit(ledger)
    ledger.abandonWait(forTicket: stalled)
    #expect {
        _ = try admit(ledger)
    } throws: { error in
        let error = error as NSError
        return error.domain == CSBHIDClientErrorDomain
            && error.code == CSBHIDClientError.transportStalled.rawValue
    }
    // Refused, not queued.
    #expect(ledger.outstandingSendCount == 1)
}

@Test
func aReleaseStillGoesOutBehindAStalledSend() throws {
    let ledger = SimHIDSendLedger()
    _ = try admit(ledger)
    _ = try admit(ledger, release: true)
    #expect(ledger.outstandingSendCount == 2)
}

@Test
func settlingWaitsForEveryOutstandingSend() throws {
    let ledger = SimHIDSendLedger()
    let stalled = try admit(ledger)
    ledger.abandonWait(forTicket: stalled)
    let release = try admit(ledger, release: true)
    let probe = SettleProbe(ledger)
    ledger.complete(ticket: stalled, error: nil)
    // One send is still out, so the wait goes on.
    #expect(ledger.outstandingSendCount == 1)
    #expect(!probe.hasFired)
    ledger.complete(ticket: release, error: nil)
    let settled = probe.wait()
    #expect(settled.didFire)
    #expect(settled.error == nil)
    #expect(ledger.outstandingSendCount == 0)
}

@Test
func settlingIsImmediateWithNothingOutstanding() {
    let settled = SettleProbe(SimHIDSendLedger()).wait()
    #expect(settled.didFire)
    #expect(settled.error == nil)
}

@Test
func aTimedOutSendThatFailsLaterIsReportedToTheNextSettleOnly() throws {
    let ledger = SimHIDSendLedger()
    let ticket = try admit(ledger)
    ledger.abandonWait(forTicket: ticket)
    let probe = SettleProbe(ledger)
    ledger.complete(ticket: ticket, error: NSError(domain: "test", code: 3))
    let settled = probe.wait()
    #expect(settled.didFire)
    #expect(settled.error?.code == 3)
    // Reported once, then cleared.
    #expect(SettleProbe(ledger).wait().error == nil)
}

@Test
func anErrorTheWaiterAlreadySawIsNotReportedAgain() throws {
    let ledger = SimHIDSendLedger()
    let ticket = try admit(ledger)
    // Completed within its wait, so its own caller got the error.
    ledger.complete(ticket: ticket, error: NSError(domain: "test", code: 3))
    #expect(SettleProbe(ledger).wait().error == nil)
}

@Test
func abandoningAnOutstandingTicketSaysSo() throws {
    let ledger = SimHIDSendLedger()
    let ticket = try admit(ledger)
    #expect(ledger.abandonWait(forTicket: ticket))
}

@Test
func abandoningACompletedTicketChangesNothingAndSaysSo() throws {
    let ledger = SimHIDSendLedger()
    let ticket = try admit(ledger)
    ledger.complete(ticket: ticket, error: NSError(domain: "test", code: 3))
    // The waiter still owns that error, so the ledger must not claim it.
    #expect(!ledger.abandonWait(forTicket: ticket))
    #expect(ledger.outstandingSendCount == 0)
    #expect(SettleProbe(ledger).wait().error == nil)
    _ = try admit(ledger)
}

@Test
func watchingForADrainLeavesTheLateErrorForTheSettle() throws {
    let ledger = SimHIDSendLedger()
    let ticket = try admit(ledger)
    ledger.abandonWait(forTicket: ticket)
    let drained = DispatchSemaphore(value: 0)
    ledger.whenDrained(on: DispatchQueue.global()) { drained.signal() }
    ledger.complete(ticket: ticket, error: NSError(domain: "test", code: 3))
    #expect(drained.wait(timeout: .now() + 5) == .success)
    // The recovery registering after the drain still hears the failure.
    #expect(SettleProbe(ledger).wait().error?.code == 3)
}

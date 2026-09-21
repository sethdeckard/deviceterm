// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// Admission on its own: what a caller gets when every display-start slot is
// held. The coordinator-level suite covers the same accounting through a
// create; this one pins the waiting itself, which a create cannot observe
// without a bootstrap in the way.

private func neverFires(_: UInt64) async throws {
    try await Task.sleep(nanoseconds: 60_000_000_000)
}

@Test
func aCallerBehindAFullCapWaitsAndTakesTheFirstFreedSlot() async throws {
    let supervisor = DisplayBootstrapSupervisor(maxInFlight: 1, sleep: neverFires)
    let held = try await supervisor.admit(udid: "udid-held")

    let waiting = Task { try await supervisor.admit(udid: "udid-waiting") }
    #expect(try await poll(timeout: 2) { await supervisor.waiting == 1 })
    #expect(await supervisor.inFlight == 1)

    await supervisor.release(token: held)
    let token = try await waiting.value
    #expect(await supervisor.waiting == 0)
    #expect(await supervisor.inFlight == 1)
    await supervisor.release(token: token)
    #expect(await supervisor.inFlight == 0)
}

@Test
func waitersAreAdmittedOldestFirst() async throws {
    let supervisor = DisplayBootstrapSupervisor(maxInFlight: 1, sleep: neverFires)
    let held = try await supervisor.admit(udid: "udid-held")
    let first = Task { try await supervisor.admit(udid: "udid-first") }
    #expect(try await poll(timeout: 2) { await supervisor.waiting == 1 })
    let second = Task { try await supervisor.admit(udid: "udid-second") }
    #expect(try await poll(timeout: 2) { await supervisor.waiting == 2 })

    await supervisor.release(token: held)
    let firstToken = try await first.value
    #expect(await supervisor.waiting == 1)

    await supervisor.release(token: firstToken)
    let secondToken = try await second.value
    #expect(await supervisor.waiting == 0)
    await supervisor.release(token: secondToken)
}

@Test
func aWaiterWhoseDeadlinePassesTimesOutWithoutASlot() async throws {
    let supervisor = DisplayBootstrapSupervisor(maxInFlight: 1, sleep: { _ in })
    let held = try await supervisor.admit(udid: "udid-held")

    await #expect(throws: PaneError.displayStartTimedOut(udid: "udid-late")) {
        try await supervisor.admit(udid: "udid-late")
    }
    #expect(await supervisor.waiting == 0)
    #expect(await supervisor.inFlight == 1)
    await supervisor.release(token: held)
}

@Test
func admitRefusesWaitersBeyondTheQueueBound() async throws {
    let supervisor = DisplayBootstrapSupervisor(maxInFlight: 1, sleep: neverFires)
    let held = try await supervisor.admit(udid: "udid-held")
    let bound = DisplayBootstrapSupervisor.waitersPerSlot
    // Each waiter gives its slot back as soon as it has it, so the queue
    // drains in whatever order the tasks reached the actor.
    let waiters = (0..<bound).map { index in
        Task { () -> Bool in
            guard let token = try? await supervisor.admit(udid: "udid-wait-\(index)") else { return false }
            await supervisor.release(token: token)
            return true
        }
    }
    #expect(try await poll(timeout: 2) { await supervisor.waiting == bound })

    await #expect(throws: PaneError.displayStartBusy(udid: "udid-over")) {
        try await supervisor.admit(udid: "udid-over")
    }

    await supervisor.release(token: held)
    for waiter in waiters {
        #expect(await waiter.value)
    }
    #expect(await supervisor.waiting == 0)
    #expect(await supervisor.inFlight == 0)
}

// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

// InventorySyncCoordinator: the single caller of `session.restoreBatch`, driving
// both restart restoration and ongoing authoritative inventory reconciliation
// behind a dirty flag with bounded coalescing. These pin: a mutation during an
// in-flight batch forces a second batch; continuous churn keeps flushing and the
// synced watermark advances only on a verified echo; a failed delivery stays
// dirty and retries; and reconnect observers fire once, only for the current
// generation.

private func session(_ id: String) -> RestoredSession {
    RestoredSession(
        sessionId: id,
        capability: "cap-\(id)",
        shortId: id,
        role: .agent,
        name: nil,
        isPrivate: false
    )
}

/// A scriptable harness driving the coordinator on the main actor.
@MainActor
private final class Harness {
    var inventory: [RestoredSession] = []
    var generation = 0
    /// Per-call outcome: return the echoed ids (nil = failure). Default echoes
    /// the sent inventory (success). A closure can mutate state mid-send.
    var onSend: (@MainActor ([RestoredSession]) async -> [String]?)?
    private(set) var sentInventories: [[String]] = []
    private(set) var reconnectFires: [[String]] = []
    private(set) var contractViolations = 0

    lazy var coordinator = InventorySyncCoordinator(
        InventorySyncCoordinator.Dependencies(
            buildInventory: { [weak self] in self?.inventory },
            sendBatch: { [weak self] inv in
                guard let self else { return nil }
                self.sentInventories.append(inv.map(\.sessionId))
                if let onSend = self.onSend { return await onSend(inv) }
                return inv.map(\.sessionId)
            },
            generation: { [weak self] in self?.generation ?? 0 },
            onReconnectSynced: { [weak self] inv in
                self?.reconnectFires.append(inv.map(\.sessionId))
            },
            reportContractViolation: { [weak self] in self?.contractViolations += 1 },
            // Instant, never-cancelled sleep so the loop runs fast.
            sleep: { _ in true },
            coalesceWindowNanos: 0,
            maxBackoffNanos: 0,
            baseBackoffNanos: 0
        )
    )

    var sendCount: Int { sentInventories.count }

    /// Spin the main actor until `predicate` holds or a bound elapses.
    func settle(_ predicate: @MainActor () -> Bool) async {
        var spins = 0
        while !predicate() {
            spins += 1
            #expect(spins < 100_000)
            await Task.yield()
        }
    }
}

@Test
@MainActor
func aSingleDirtyMarkSendsOneVerifiedBatch() async {
    let harness = Harness()
    harness.inventory = [session("a"), session("b")]
    harness.coordinator.markDirty()
    await harness.settle { harness.coordinator.isSettled }
    #expect(harness.sendCount == 1)
    #expect(harness.sentInventories.last == ["a", "b"])
}

@Test
@MainActor
func aMutationDuringAnInFlightBatchForcesASecondBatch() async {
    let harness = Harness()
    harness.inventory = [session("a")]
    // On the first send, mutate the workspace (remove a) and mark dirty: this
    // must force a second batch reflecting the new inventory.
    var firstSend = true
    harness.onSend = { inv in
        if firstSend {
            firstSend = false
            harness.inventory = []
            harness.coordinator.markDirty()
        }
        return inv.map(\.sessionId)
    }
    harness.coordinator.markDirty()
    await harness.settle { harness.coordinator.isSettled }
    #expect(harness.sendCount == 2)
    #expect(harness.sentInventories.first == ["a"])
    #expect(harness.sentInventories.last?.isEmpty == true)
}

@Test
@MainActor
func continuousChurnKeepsFlushingAndWatermarkAdvancesOnlyOnVerifiedEcho() async {
    let harness = Harness()
    harness.inventory = [session("a")]
    // The first few sends return an UNVERIFIED echo (wrong set) so the watermark
    // must not advance; then a verified one lets it settle.
    var sends = 0
    harness.onSend = { inv in
        sends += 1
        if sends < 3 { return ["mismatch"] }  // unverified → stays dirty, retries
        return inv.map(\.sessionId)
    }
    harness.coordinator.markDirty()
    await harness.settle { harness.coordinator.isSettled }
    // It retried until a verified echo (>= 3 sends), then settled.
    #expect(harness.sendCount >= 3)
    #expect(harness.coordinator.isSettled)
}

@Test
@MainActor
func aFailedDeliveryStaysDirtyAndRetries() async {
    let harness = Harness()
    harness.inventory = [session("a")]
    var sends = 0
    harness.onSend = { inv in
        sends += 1
        return sends < 2 ? nil : inv.map(\.sessionId)  // first send fails
    }
    harness.coordinator.markDirty()
    await harness.settle { harness.coordinator.isSettled }
    #expect(harness.sendCount == 2)  // failed once, retried, verified
}

@MainActor
final class MutableBox {
    var passes = 0
    var sent: [[String]] = []
    var violations = 0
}

@Test
@MainActor
func aContractViolationIsSurfacedAndRetried() async {
    // First inventory build is unresolvable (nil) → surfaced + retried; the next
    // build succeeds and sends.
    let box = MutableBox()
    let coordinator = InventorySyncCoordinator(
        InventorySyncCoordinator.Dependencies(
            buildInventory: {
                box.passes += 1
                return box.passes < 2 ? nil : [session("a")]
            },
            sendBatch: { inv in
                box.sent.append(inv.map(\.sessionId))
                return inv.map(\.sessionId)
            },
            generation: { 0 },
            onReconnectSynced: { _ in },
            reportContractViolation: { box.violations += 1 },
            sleep: { _ in true },
            coalesceWindowNanos: 0,
            maxBackoffNanos: 0,
            baseBackoffNanos: 0
        )
    )
    coordinator.markDirty()
    var spins = 0
    while !coordinator.isSettled {
        spins += 1
        #expect(spins < 100_000)
        await Task.yield()
    }
    #expect(box.violations == 1)
    #expect(box.sent.last == ["a"])
}

@Test
@MainActor
func reconnectFiresObserversOnceForTheCurrentGenerationOnly() async {
    let harness = Harness()
    harness.inventory = [session("a")]
    harness.generation = 5
    harness.coordinator.reconnected(generation: 5)
    await harness.settle { harness.coordinator.isSettled }
    #expect(harness.reconnectFires == [["a"]])

    // A steady-state markDirty does NOT fire reconnect observers again.
    harness.inventory = [session("a"), session("b")]
    harness.coordinator.markDirty()
    await harness.settle { harness.coordinator.isSettled }
    #expect(harness.reconnectFires == [["a"]])
}

@Test
@MainActor
func aStaleReplyAfterReconnectDoesNotConsumeTheNewGenerationsFire() async {
    // A generation-1 send's verified reply lands AFTER an actual reconnected(2).
    // It must not fire (its send generation is stale) nor consume generation 2's
    // notification; only the gen-2 sync fires, with the FRESH gen-2 inventory.
    let harness = Harness()
    harness.inventory = [session("a")]
    harness.generation = 1
    var firstSend = true
    harness.onSend = { inv in
        if firstSend {
            firstSend = false
            harness.generation = 2
            harness.inventory = [session("b")]
            harness.coordinator.reconnected(generation: 2)
        }
        return inv.map(\.sessionId)
    }
    harness.coordinator.reconnected(generation: 1)
    await harness.settle { harness.coordinator.isSettled }
    #expect(harness.reconnectFires == [["b"]])
}

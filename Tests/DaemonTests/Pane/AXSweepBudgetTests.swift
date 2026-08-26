// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// What the sweep does when it can't finish its grid inside the budget: it
// stops between cells and says so, rather than passing partial coverage off
// as the whole screen. The budget covers the wait for the pane's
// accessibility queue too, which is what keeps stacked sweeps bounded.

private func sweepRoot(
    backend: MockDeviceBackend,
    queue: BlockingWorkQueue = BlockingWorkQueue(label: "test.sweep.budget"),
    step: Double? = nil,
    budgetMs: Int = AXSweep.maxDurationMs
) async throws -> [String: Any] {
    let data = try await PaneAccessibility.sweep(
        backend: backend,
        queue: queue,
        paneId: UUID(),
        orientation: { .portrait },
        step: step,
        budgetMs: budgetMs
    )
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return try #require(root)
}

private func phoneBackend(probes: ProbeCounter? = nil) -> MockDeviceBackend {
    let backend = MockDeviceBackend()
    backend.frontmostTree = ["frame": ["x": 0, "y": 0, "w": 400, "h": 800]]
    backend.onFrontmostTree = { probes?.bump() }
    return backend
}

/// Counts the sweep's pre-flight probe. The mock records per-cell queries
/// but not the tree read, and a sweep whose deadline is already expired when
/// it reaches the queue has to skip both.
private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var calls: Int {
        lock.lock(); defer { lock.unlock() }; return value
    }

    func bump() {
        lock.lock(); defer { lock.unlock() }; value += 1
    }
}

@Test
func aSweepThatFinishesReportsItsWholeGrid() async throws {
    let backend = phoneBackend()
    let cells = AXSweep.gridPoints(step: AXSweep.defaultStep).count

    // An explicit, generous budget rather than the real one: this asserts
    // a completed walk, and pinning it to a wall clock would let a loaded
    // machine truncate the sweep and fail the test for no defect. The real
    // constant is pinned below.
    let root = try await sweepRoot(backend: backend, budgetMs: 600_000)

    #expect(root["truncated"] as? Bool == false)
    #expect(root["sweepedPoints"] as? Int == cells)
    #expect(backend.accessibilityPoints.count == cells)
}

@Test
func aSweepOutOfBudgetAnswersShortAndSaysSo() async throws {
    let probes = ProbeCounter()
    let backend = phoneBackend(probes: probes)

    // A spent budget is the same decision the walk makes mid-grid, taken
    // before the first cell so the test doesn't have to race a clock.
    let root = try await sweepRoot(backend: backend, budgetMs: 0)

    #expect(root["truncated"] as? Bool == true)
    #expect(root["sweepedPoints"] as? Int == 0)
    // The point of the deadline: an already-expired sweep doesn't occupy
    // the pane's accessibility queue with new bridge work.
    #expect(backend.accessibilityPoints.isEmpty)
    #expect(probes.calls == 0)
    // Still a well-formed wrapper, so a caller reads a partial answer
    // rather than a transport failure.
    #expect(root["role"] as? String == "AXSweepRoot")
    #expect(root["step"] as? Double == AXSweep.defaultStep)
}

@Test
func timeSpentWaitingForTheQueueComesOutOfTheBudget() async throws {
    let probes = ProbeCounter()
    let backend = phoneBackend(probes: probes)
    let queue = BlockingWorkQueue(label: "test.sweep.queued")
    // Occupy the pane's serial queue the way a sweep or an `ax tree` ahead
    // of this one would. The wide margin between the two is deliberate: a
    // sleep can only overrun, so no amount of load makes this a race.
    queue.submit { Thread.sleep(forTimeInterval: 1) }

    let root = try await sweepRoot(backend: backend, queue: queue, budgetMs: 20)

    // Spent before the walk ever started. A deadline taken on reaching the
    // queue would instead have granted this sweep a fresh budget on top of
    // the second it waited, and stacked sweeps would outlast the client.
    #expect(root["truncated"] as? Bool == true)
    #expect(backend.accessibilityPoints.isEmpty)
    // Not even the pre-flight: that probe is a synchronous bridge call with
    // no bound, so making it would hold the queue past the deadline.
    #expect(probes.calls == 0)
}

@Test
func aGridThatFinishesIsNotTruncatedEvenWhenItsLastQueryOverran() async throws {
    let backend = phoneBackend()
    // The coarsest legal step is a four-cell grid, so the slow call is the
    // last one and the three before it are instant.
    backend.slowElementCall = (index: 3, seconds: 1)

    let root = try await sweepRoot(backend: backend, step: AXSweep.maxStep, budgetMs: 300)

    // Every check ran before the deadline, so the walk queried all four
    // cells and the last one carried it well past. Nothing checks after the
    // final cell, so this reports untruncated despite overrunning, which is
    // the caveat the docs carry.
    #expect(root["truncated"] as? Bool == false)
    #expect(root["sweepedPoints"] as? Int == 4)
    #expect(backend.accessibilityPoints.count == 4)
}

@Test(arguments: [(0.05, 400), (0.02, 2_500), (0.08, 169), (0.03, 1_156), (0.5, 4)])
func aGridHoldsCeilOfTheReciprocalSquared(step: Double, expected: Int) {
    // The count the help text, USAGE, and the man page all quote. It is
    // `ceil(1/step)^2`, not `(1/step)^2`: a step whose reciprocal isn't whole
    // still emits a final row and column below 1.0, so 0.08 makes 169 queries
    // rather than 156.
    #expect(AXSweep.gridPoints(step: step).count == expected)
}

@Test
func theSweepBudgetOutlastsTheDefaultGridAndBoundsTheFinestOne() {
    // Under the bridge's approximate 5ms-per-cell cost, the default grid
    // fits inside the daemon's deadline. Cell counts, not measured time.
    let defaultCells = AXSweep.gridPoints(step: AXSweep.defaultStep).count
    let finestCells = AXSweep.gridPoints(step: AXSweep.minStep).count
    #expect(defaultCells * 5 < AXSweep.maxDurationMs)
    // Under the same estimate, the finest grid exceeds that deadline, which
    // is the case the deadline exists for.
    #expect(finestCells * 5 > AXSweep.maxDurationMs)
}

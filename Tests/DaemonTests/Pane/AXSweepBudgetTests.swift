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
    budgetMs: Int? = nil
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

    // The ceiling rather than the default: this asserts a completed walk, and
    // pinning it to a tighter wall clock would let a loaded machine truncate
    // the sweep and fail the test for no defect. The default is pinned below.
    let root = try await sweepRoot(backend: backend, budgetMs: AXSweepBudget.maxMs)

    #expect(root["truncated"] as? Bool == false)
    #expect(root["sweepedPoints"] as? Int == cells)
    #expect(backend.accessibilityPoints.count == cells)
    // A completed sweep says so and stays silent, so the note is a signal
    // rather than boilerplate every response carries.
    #expect(root["note"] == nil)
    #expect(root["noteCode"] == nil)
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
    #expect(root["budgetMs"] as? Int == 0)
    // Truncation is what raises the note, including on the path that never
    // reached the bridge: a caller reading only `note` still learns the
    // coverage is partial. Which of the two it gets is `AXTreeNote`'s call,
    // covered in `DaemonProtocolTests`.
    #expect(root["note"] as? String
        == AXTreeNote.forTruncatedSweep(budgetMs: 0).rawValue)
    // The sentence is for a human; the token is what a client branches on,
    // since the two truncation notes differ only in prose.
    #expect(root["noteCode"] as? String
        == AXTreeNote.forTruncatedSweep(budgetMs: 0).code)
}

@Test
func theBudgetTheSweepRanUnderIsEchoedBackPostClamp() async throws {
    // The clamp is silent, the same way `step`'s is, so the echo is the only
    // way a caller who asked for an hour can tell they got a minute.
    let overCeiling = try await sweepRoot(
        backend: phoneBackend(),
        step: AXSweep.maxStep,
        budgetMs: AXSweepBudget.maxMs * 60
    )
    #expect(overCeiling["budgetMs"] as? Int == AXSweepBudget.maxMs)

    // A negative request is a zero-length walk, not a deadline in the past.
    let negative = try await sweepRoot(backend: phoneBackend(), budgetMs: -5_000)
    #expect(negative["budgetMs"] as? Int == 0)
    #expect(negative["truncated"] as? Bool == true)

    // An unspecified budget resolves the shared default, which is what makes
    // the field readable without knowing whether the caller named one.
    let unspecified = try await sweepRoot(
        backend: phoneBackend(),
        step: AXSweep.maxStep,
        budgetMs: nil
    )
    #expect(unspecified["budgetMs"] as? Int == AXSweepBudget.defaultMs)
}

@Test
func aLongerBudgetReachesCellsTheDefaultWouldHaveStoppedShortOf() async throws {
    // A timing model in miniature: the same grid truncates when its per-cell
    // cost outruns the budget and completes when the budget covers it. Four
    // cells, the third of which is slow, stands in for a floor grid against
    // the bridge's real cost.
    let cells = AXSweep.gridPoints(step: AXSweep.maxStep).count

    let cramped = phoneBackend()
    cramped.slowElementCall = (index: 2, seconds: 1)
    let short = try await sweepRoot(backend: cramped, step: AXSweep.maxStep, budgetMs: 200)
    #expect(short["truncated"] as? Bool == true)
    #expect((short["sweepedPoints"] as? Int ?? cells) < cells)

    let paid = phoneBackend()
    paid.slowElementCall = (index: 2, seconds: 1)
    let full = try await sweepRoot(backend: paid, step: AXSweep.maxStep, budgetMs: 30_000)
    #expect(full["truncated"] as? Bool == false)
    #expect(full["sweepedPoints"] as? Int == cells)
    #expect(full["note"] == nil)
    #expect(full["noteCode"] == nil)
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
func theDefaultBudgetCoversTheDefaultGridButNotTheFinestOne() {
    // Under the bridge's approximate 5ms-per-cell cost, the default grid
    // fits inside the default budget. Cell counts, not measured time.
    let defaultCells = AXSweep.gridPoints(step: AXSweep.defaultStep).count
    let finestCells = AXSweep.gridPoints(step: AXSweep.minStep).count
    #expect(defaultCells * 5 < AXSweepBudget.defaultMs)
    // Under the same estimate the finest grid does not, which is what makes
    // the budget worth buying. Live completion still turns on host latency;
    // this pins the model the constants were chosen against.
    #expect(finestCells * 5 > AXSweepBudget.defaultMs)
    // The ceiling covers it under that model, so `--budget` is a real remedy
    // rather than a knob that runs out before the finest legal step.
    #expect(finestCells * 5 < AXSweepBudget.maxMs)
}

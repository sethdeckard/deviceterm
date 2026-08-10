// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// Status item visibility is the daemon's "alive holding sims"
// signal. The title format is documented in docs/ARCHITECTURE.md and
// the GUI smoke tests rely on this exact shape, so pin it here.

@Test
func statusItemTitleHiddenWhenZeroSims() {
    #expect(StatusItemController.titleForCount(0) == nil)
}

@Test
func statusItemTitleShowsPhoneEmojiAndCount() {
    #expect(StatusItemController.titleForCount(1) == "📱 1")
    #expect(StatusItemController.titleForCount(2) == "📱 2")
    #expect(StatusItemController.titleForCount(10) == "📱 10")
}

@Test
func statusItemTitleRejectsNegativeAsHidden() {
    // Defensive: ownership counts can't be negative in practice,
    // but the formatter shouldn't render an impossible value as a
    // visible title. Treat anything ≤ 0 as hidden.
    #expect(StatusItemController.titleForCount(-1) == nil)
}

// MARK: - groupedStatusMenuRows

private let sessionA = UUID()
private let sessionB = UUID()
private let sessionC = UUID()

private func sim(
    udid: String,
    name: String = "iPhone 17 Pro",
    sessionId: UUID? = nil
) -> OwnedSim {
    OwnedSim(
        udid: udid,
        name: name,
        runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
        sessionId: sessionId
    )
}

@Test
func groupedRowsCarryOwningSessionName() {
    let sims = [
        sim(udid: "11111111-...", sessionId: sessionA),
        sim(udid: "22222222-...", sessionId: sessionA)
    ]
    let names: [UUID: String] = [sessionA: "auth-feature"]
    let rows = groupedStatusMenuRows(sims) { names[$0] }
    #expect(rows.map(\.groupHeader) == ["auth-feature", "auth-feature"])
}

@Test
func groupedRowsReportUnlinkedHeaderForOrphans() {
    // An orphan sim: owned by the daemon but its session record
    // has been closed (or was never present, e.g. cold-start
    // recovery before a re-attach).
    let sims = [sim(udid: "ABCD-...", sessionId: nil)]
    let rows = groupedStatusMenuRows(sims) { _ in nil }
    #expect(rows.first?.groupHeader == nil)
}

@Test
func groupedRowsPreserveCoreSimulatorEnumerationOrder() {
    // Grouping must not reorder rows, because the status item renders
    // section headers inline as the headers change, so the
    // CoreSimulator order is the menu order.
    let sims = [
        sim(udid: "1", sessionId: sessionA),
        sim(udid: "2", sessionId: sessionB),
        sim(udid: "3", sessionId: sessionA)
    ]
    let names: [UUID: String] = [sessionA: "A", sessionB: "B"]
    let rows = groupedStatusMenuRows(sims) { names[$0] }
    #expect(rows.map(\.udid) == ["1", "2", "3"])
    #expect(rows.map(\.groupHeader) == ["A", "B", "A"])
}

@Test
func groupedRowsCarryDisambiguatedTitles() {
    // Same-name sims in the same group still get the disambiguation
    // suffix from `statusMenuEntries` so the user can tell them
    // apart by UDID prefix at a glance.
    let sims = [
        sim(udid: "00000000-aaaa", name: "iPhone 17 Pro", sessionId: sessionA),
        sim(udid: "11111111-bbbb", name: "iPhone 17 Pro", sessionId: sessionA)
    ]
    let names: [UUID: String] = [sessionA: "agent"]
    let rows = groupedStatusMenuRows(sims) { names[$0] }
    #expect(rows.allSatisfy { $0.title.contains("iPhone 17 Pro — ") })
}

@Test
func groupedRowsFallBackWhenSessionNameMissing() {
    // sessionId set but the lookup closure returns nil, meaning the
    // session was closed between the device snapshot and the menu
    // build, or the test is exercising the partial-data path.
    // Treated as "Unlinked" so the menu still renders.
    let sims = [sim(udid: "X", sessionId: sessionC)]
    let rows = groupedStatusMenuRows(sims) { _ in nil }
    #expect(rows.first?.groupHeader == nil)
}

// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// The two zones of a tab array: a pinned prefix and the unpinned rest.
/// Indices are post-removal, so `totalOthers` excludes the tab being placed.
struct TabPinZoneMathTests {
    @Test("insertion range by zone", arguments: [
        // pinned, pinnedOthers, totalOthers, expected
        (true, 0, 3, 0...0),
        (true, 2, 5, 0...2),
        (false, 0, 3, 0...3),
        (false, 2, 5, 2...5),
        (false, 3, 3, 3...3)
    ])
    func insertionRange(pinned: Bool, pinnedOthers: Int, totalOthers: Int, expected: ClosedRange<Int>) {
        #expect(
            TabPinZoneMath.insertionRange(
                pinned: pinned,
                pinnedOthers: pinnedOthers,
                totalOthers: totalOthers
            ) == expected
        )
    }

    @Test("clamps into the zone from either side", arguments: [
        // index, pinned, pinnedOthers, totalOthers, expected
        (5, true, 2, 5, 2),     // pinned tab asked into the unpinned run
        (-1, true, 2, 5, 0),
        (1, true, 2, 5, 1),     // inside the zone: untouched
        (0, false, 2, 5, 2),    // unpinned tab asked into the pinned run
        (99, false, 2, 5, 5),
        (3, false, 2, 5, 3)
    ])
    func clampsIntoZone(index: Int, pinned: Bool, pinnedOthers: Int, totalOthers: Int, expected: Int) {
        #expect(
            TabPinZoneMath.clampedInsertion(
                index,
                pinned: pinned,
                pinnedOthers: pinnedOthers,
                totalOthers: totalOthers
            ) == expected
        )
    }
}

/// `TabListViewModel` keeps pinned tabs a contiguous prefix through every
/// mutation that places a tab.
@MainActor
struct TabListViewModelPinningTests {
    private func tab(_ value: Int, pinned: Bool = false) -> TabState {
        TabState(
            id: TabID(value: value),
            terminals: [
                TerminalPaneState(
                    id: TerminalPaneID(value: value),
                    sessionId: "S\(value)",
                    capability: "C\(value)"
                )
            ],
            simPanes: [],
            isPinned: pinned
        )
    }

    private func order(_ model: TabListViewModel) -> [Int] { model.tabs.map(\.id.value) }

    private func pinned(_ model: TabListViewModel) -> [Int] {
        model.tabs.filter(\.isPinned).map(\.id.value)
    }

    /// The invariant itself: no unpinned tab precedes a pinned one.
    private func holdsPrefix(_ model: TabListViewModel) -> Bool {
        model.tabs.drop(while: \.isPinned).allSatisfy { !$0.isPinned }
    }

    @Test
    func appendPlacesPinnedTabAtTheEndOfThePinnedRun() {
        let model = TabListViewModel()
        model.append(tab(1))
        model.append(tab(2, pinned: true))
        model.append(tab(3))
        model.append(tab(4, pinned: true))
        #expect(order(model) == [2, 4, 1, 3])
        #expect(model.pinnedCount == 2)
        // Appending still selects the new tab, wherever it landed.
        #expect(model.selectedTab?.id == TabID(value: 4))
    }

    @Test
    func moveKeepsAnUnpinnedTabOutOfThePinnedRun() {
        let model = TabListViewModel()
        [tab(1, pinned: true), tab(2, pinned: true), tab(3), tab(4)].forEach(model.append)
        model.move(id: TabID(value: 4), toIndex: 0)
        #expect(order(model) == [1, 2, 4, 3])
    }

    @Test
    func moveKeepsAPinnedTabInsideThePinnedRun() {
        let model = TabListViewModel()
        [tab(1, pinned: true), tab(2, pinned: true), tab(3), tab(4)].forEach(model.append)
        model.move(id: TabID(value: 1), toIndex: 99)
        #expect(order(model) == [2, 1, 3, 4])
    }

    @Test
    func insertClampsARelocatedTabIntoItsZone() {
        let model = TabListViewModel()
        [tab(1, pinned: true), tab(2)].forEach(model.append)
        model.insert(tab(3), at: 0)
        model.insert(tab(4, pinned: true), at: 3)
        #expect(order(model) == [1, 4, 3, 2])
        #expect(model.selectedTab?.id == TabID(value: 4))
    }

    @Test
    func pinningMovesATabToTheEndOfThePinnedRun() {
        let model = TabListViewModel()
        [tab(1, pinned: true), tab(2), tab(3), tab(4)].forEach(model.append)
        model.setPinned(id: TabID(value: 4), true)
        #expect(order(model) == [1, 4, 2, 3])
        #expect(pinned(model) == [1, 4])
    }

    @Test
    func unpinningMovesATabToTheHeadOfTheUnpinnedTabs() {
        let model = TabListViewModel()
        [tab(1, pinned: true), tab(2, pinned: true), tab(3)].forEach(model.append)
        model.setPinned(id: TabID(value: 1), false)
        #expect(order(model) == [2, 1, 3])
        #expect(pinned(model) == [2])
    }

    @Test
    func pinningFollowsTheSelectionByIdentity() {
        let model = TabListViewModel()
        [tab(1), tab(2), tab(3)].forEach(model.append)
        model.select(id: TabID(value: 2))
        model.setPinned(id: TabID(value: 3), true)
        #expect(order(model) == [3, 1, 2])
        #expect(model.selectedTab?.id == TabID(value: 2))
    }

    @Test
    func pinningAnAlreadyPinnedTabChangesNothing() {
        let model = TabListViewModel()
        [tab(1, pinned: true), tab(2, pinned: true), tab(3)].forEach(model.append)
        model.setPinned(id: TabID(value: 1), true)
        #expect(order(model) == [1, 2, 3])
    }

    @Test
    func thePinnedPrefixSurvivesMixedOperations() {
        let model = TabListViewModel()
        (1...5).forEach { model.append(tab($0)) }
        model.setPinned(id: TabID(value: 3), true)
        model.move(id: TabID(value: 5), toIndex: 0)
        model.setPinned(id: TabID(value: 5), true)
        model.move(id: TabID(value: 3), toIndex: 4)
        model.insert(tab(6, pinned: true), at: 5)
        model.setPinned(id: TabID(value: 5), false)
        model.removeTab(id: TabID(value: 6))
        #expect(holdsPrefix(model))
        #expect(order(model) == [3, 5, 1, 2, 4])
        #expect(pinned(model) == [3])
    }
}

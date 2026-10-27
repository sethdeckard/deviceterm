// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

/// Canonical (lowercase) spellings, the form a sanitized layout carries.
private let udidA = "6f9619ff-8b86-d011-b42d-00c04fc964ff"

private func term(_ cwd: String? = nil) -> WorkspaceSnapshot.Node {
    .terminal(.init(cwd: cwd, name: nil))
}

private func sim(_ udid: String) -> WorkspaceSnapshot.Node {
    .sim(.init(id: udid, displayName: nil, name: nil, family: nil, sizePreset: nil))
}

private func device(_ id: String) -> WorkspaceSnapshot.Node {
    .device(.init(id: id, displayName: nil, name: nil, family: nil, sizePreset: nil))
}

@Suite
struct WorkspaceRestoreLayoutTests {
    @Test
    func keepsAValidLayoutWhole() {
        let layout = WorkspaceSnapshot.Node.split(
            axis: .horizontal,
            children: [term("/a"), .split(axis: .vertical, children: [sim(udidA), term()], ratios: [0.7, 0.3])],
            ratios: [0.4, 0.6]
        )
        let sanitized = WorkspaceRestoreLayout.sanitized(layout)
        #expect(sanitized.node == layout)
        #expect(sanitized.kept == [0, 1, 2])
    }

    @Test
    func canonicalizesSimUDIDs() {
        let sanitized = WorkspaceRestoreLayout.sanitized(sim(udidA.uppercased()))
        guard case let .sim(device)? = sanitized.node else {
            Issue.record("expected a sim leaf")
            return
        }
        #expect(device.id == udidA)
    }

    @Test
    func dropsASimThatIsNotAUUIDAndCollapsesItsSplit() {
        let layout = WorkspaceSnapshot.Node.split(
            axis: .horizontal,
            children: [term("/a"), sim("not-a-udid")],
            ratios: [0.5, 0.5]
        )
        let sanitized = WorkspaceRestoreLayout.sanitized(layout)
        #expect(sanitized.node == term("/a"))
        #expect(sanitized.kept == [0])
    }

    @Test
    func keepsTheFirstOfTwoLeavesForOneTarget() {
        let layout = WorkspaceSnapshot.Node.split(
            axis: .horizontal,
            children: [term(), sim(udidA), sim(udidA), device("D"), device("D"), device("")],
            ratios: nil
        )
        let sanitized = WorkspaceRestoreLayout.sanitized(layout)
        #expect(sanitized.node == .split(axis: .horizontal, children: [term(), sim(udidA), device("D")], ratios: nil))
        #expect(sanitized.kept == [0, 1, 3])
    }

    @Test("proportions that don't fit their split are dropped", arguments: [
        [0.5],
        [0.5, 0.0],
        [0.5, -1.0],
        [Double.nan, 0.5],
        [Double.infinity, 0.5]
    ])
    func dropsUnusableRatios(ratios: [Double]) {
        let layout = WorkspaceSnapshot.Node.split(axis: .vertical, children: [term(), term()], ratios: ratios)
        #expect(
            WorkspaceRestoreLayout.sanitized(layout).node
                == .split(axis: .vertical, children: [term(), term()], ratios: nil)
        )
    }

    @Test
    func aSplitThatLosesAChildDropsItsRatiosButItsParentKeepsTheirs() {
        let layout = WorkspaceSnapshot.Node.split(
            axis: .horizontal,
            children: [
                term("/a"),
                .split(axis: .vertical, children: [term("/b"), sim("bogus"), term("/c")], ratios: [0.2, 0.3, 0.5])
            ],
            ratios: [0.4, 0.6]
        )
        #expect(
            WorkspaceRestoreLayout.sanitized(layout).node == .split(
                axis: .horizontal,
                children: [term("/a"), .split(axis: .vertical, children: [term("/b"), term("/c")], ratios: nil)],
                ratios: [0.4, 0.6]
            )
        )
    }

    @Test
    func anEmptyLayoutRestoresNothing() {
        #expect(WorkspaceRestoreLayout.sanitized(sim("bogus")).node == nil)
        #expect(!WorkspaceRestoreLayout.hasTerminal(sim(udidA)))
        let mixed = WorkspaceSnapshot.Node.split(axis: .vertical, children: [sim(udidA), term()], ratios: nil)
        #expect(WorkspaceRestoreLayout.hasTerminal(mixed))
    }

    @Test
    func removingLeavesReportsWhereTheRestCameFrom() {
        let layout = WorkspaceSnapshot.Node.split(
            axis: .horizontal,
            children: [term("/a"), term("/b"), sim(udidA)],
            ratios: [0.2, 0.3, 0.5]
        )
        let remaining = WorkspaceRestoreLayout.removing(leaves: [1], from: layout)
        #expect(remaining.node == .split(axis: .horizontal, children: [term("/a"), sim(udidA)], ratios: nil))
        #expect(remaining.kept == [0, 2])
    }

    @Test
    func buildMapsLeavesOntoSlotsWithRatiosAndFitPaths() {
        let layout = WorkspaceSnapshot.Node.split(
            axis: .horizontal,
            children: [term(), .split(axis: .vertical, children: [sim(udidA), device("D")], ratios: [3, 1])],
            ratios: nil
        )
        let slots: [PaneSlot] = [
            .terminal(TerminalPaneID(value: 7)),
            .pending(PendingPaneID(value: 1)),
            .pending(PendingPaneID(value: 2))
        ]
        let built = WorkspaceRestoreLayout.build(layout, slots: slots)
        #expect(
            built.tree == .split(
                axis: .horizontal,
                children: [
                    .leaf(slots[0]),
                    .split(axis: .vertical, children: [.leaf(slots[1]), .leaf(slots[2])], extents: [0.75, 0.25])
                ],
                extents: [0.5, 0.5]
            )
        )
        // Only splits with saved proportions seed them; the rest size as new.
        #expect(built.ratios == [[1]: [0.75, 0.25]])
        #expect(built.simFitPaths == [.sim(udid: udidA): [1, 0]])
    }

    @Test
    func restorableDirectoryFallsBackToHome() {
        let isDirectory: (String) -> Bool = { $0 == "/work" }
        #expect(WorkspaceRestoreLayout.restorableDirectory("/work", home: "/h", isDirectory: isDirectory) == "/work")
        #expect(WorkspaceRestoreLayout.restorableDirectory("/gone", home: "/h", isDirectory: isDirectory) == "/h")
        #expect(WorkspaceRestoreLayout.restorableDirectory("work", home: "/h", isDirectory: { _ in true }) == "/h")
        #expect(WorkspaceRestoreLayout.restorableDirectory(nil, home: "/h", isDirectory: isDirectory) == "/h")
    }
}

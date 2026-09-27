// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// What a pinned pill draws in place of its title.
@Suite("pinned tab glyphs")
struct TabPinnedGlyphDecisionTests {
    /// The markers exactly as an unpinned pill orders them, and the terminal
    /// glyph only when there are none, so no pinned pill is ever empty.
    @Test("glyphs per role and protection", arguments: [
        (SessionRole.agent, false, [TabPillMarker.terminal]),
        (SessionRole.automation, false, [TabPillMarker.automation]),
        (SessionRole.agent, true, [TabPillMarker.protection]),
        (SessionRole.automation, true, [TabPillMarker.automation, .protection])
    ])
    func glyphsForEachCombination(role: SessionRole, isProtected: Bool, expected: [TabPillMarker]) {
        #expect(
            TabPinnedGlyphDecision.glyphs(role: role, isEffectivelyProtected: isProtected) == expected
        )
    }

    @Test
    func toolTipLeadsWithTheTitleThenExplainsEachMarker() {
        let tip = TabPinnedGlyphDecision.toolTip(
            title: "build-bridge",
            glyphs: [.automation, .protection]
        )
        #expect(tip.split(separator: "\n").map(String.init) == [
            "build-bridge",
            TabPillMarker.automation.hoverText,
            TabPillMarker.protection.hoverText
        ].compactMap(\.self))
    }

    /// The terminal glyph says nothing the title does not.
    @Test
    func toolTipOfAPlainTabIsItsTitle() {
        #expect(TabPinnedGlyphDecision.toolTip(title: "zsh", glyphs: [.terminal]) == "zsh")
    }
}

/// Close Other Tabs and Close Tabs to the Right never reach a pinned tab.
@MainActor
struct TabBulkCloseTargetsTests {
    private var strip: [TabState] {
        [tab(1, pinned: true), tab(2, pinned: true), tab(3), tab(4), tab(5)]
    }

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

    private func ids(_ values: [Int]) -> [TabID] { values.map { TabID(value: $0) } }

    @Test
    func othersSkipsPinnedTabs() {
        #expect(TabBulkCloseTargets.others(of: TabID(value: 4), in: strip) == ids([3, 5]))
    }

    @Test
    func othersFromAPinnedTabTakesOnlyTheUnpinned() {
        #expect(TabBulkCloseTargets.others(of: TabID(value: 1), in: strip) == ids([3, 4, 5]))
    }

    @Test
    func toTheRightFromAPinnedTabSkipsTheRestOfThePinnedRun() {
        #expect(TabBulkCloseTargets.toTheRight(of: TabID(value: 1), in: strip) == ids([3, 4, 5]))
    }

    @Test
    func toTheRightFromTheLastTabIsEmpty() {
        #expect(TabBulkCloseTargets.toTheRight(of: TabID(value: 5), in: strip).isEmpty)
    }

    /// The menu disables Close Other Tabs from this answer, so a window whose
    /// other tabs are all pinned offers nothing to close.
    @Test
    func othersIsEmptyWhenEveryOtherTabIsPinned() {
        let tabs = [tab(1, pinned: true), tab(2)]
        #expect(TabBulkCloseTargets.others(of: TabID(value: 2), in: tabs).isEmpty)
    }

    @Test
    func anUnknownTabHasNoTargets() {
        #expect(TabBulkCloseTargets.others(of: TabID(value: 99), in: strip).isEmpty)
        #expect(TabBulkCloseTargets.toTheRight(of: TabID(value: 99), in: strip).isEmpty)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// Which positions the strip badges, and which it deliberately leaves bare.
///
/// The badge is a promise that the chord works, so the interesting cases are
/// the ones where a plausible rule would over-promise: a ninth tab that no
/// chord reaches, and a last tab that ⌘9 does.
struct TabShortcutDecisionTests {
    @Test(arguments: [
        (0, KeybindingAction.selectTab1),
        (1, .selectTab2),
        (2, .selectTab3),
        (3, .selectTab4),
        (4, .selectTab5),
        (5, .selectTab6),
        (6, .selectTab7),
        (7, .selectTab8)
    ])
    func thefirstEightPositionsTakeTheirOwnNumber(index: Int, expected: KeybindingAction) {
        #expect(TabShortcutDecision.action(atIndex: index, tabCount: 12) == expected)
    }

    /// ⌘9 addresses the end of the strip rather than the ninth position, so it
    /// lands on the last tab however many there are.
    @Test(arguments: [9, 10, 12, 30])
    func theLastTabTakesTheLastTabChord(tabCount: Int) {
        #expect(
            TabShortcutDecision.action(atIndex: tabCount - 1, tabCount: tabCount)
                == .selectLastTab
        )
    }

    /// The case the badge exists to get right: with twelve tabs open, the
    /// ninth through eleventh answer to no chord at all and must not claim one.
    @Test(arguments: [8, 9, 10])
    func positionsPastTheEighthShowNothing(index: Int) {
        #expect(TabShortcutDecision.action(atIndex: index, tabCount: 12) == nil)
    }

    /// A short strip never reaches the last-tab arm, so its final tab keeps its
    /// own number instead of being relabelled ⌘9.
    @Test(arguments: [1, 2, 5, 8])
    func aShortStripsLastTabKeepsItsNumber(tabCount: Int) {
        let action = TabShortcutDecision.action(atIndex: tabCount - 1, tabCount: tabCount)
        #expect(action != .selectLastTab)
        #expect(action != nil)
    }

    /// Exactly nine tabs is the boundary: the ninth is both "past the eighth"
    /// and "the last", and the last-tab arm is the one that wins.
    @Test
    func theNinthOfNineIsTheLastTab() {
        #expect(TabShortcutDecision.action(atIndex: 8, tabCount: 9) == .selectLastTab)
    }

    @Test(arguments: [-1, 3, 99])
    func outOfRangeIndicesShowNothing(index: Int) {
        #expect(TabShortcutDecision.action(atIndex: index, tabCount: 3) == nil)
    }

    /// The badge and the menu have to name the same tab. `TabSelectionMath`
    /// resolves a menu tag to an index; this resolves an index to an action.
    /// Round-tripping the positional cases is what pins them together, since a
    /// disagreement would send the user to a tab other than the one labelled.
    @MainActor
    @Test(arguments: [3, 8, 12])
    func positionalBadgesRoundTripThroughTheMenuTag(tabCount: Int) {
        for index in 0..<min(tabCount, 8) {
            guard let action = TabShortcutDecision.action(atIndex: index, tabCount: tabCount),
                let entry = KeybindingCatalog.entry(for: action)
            else {
                Issue.record("no catalog row for index \(index)")
                continue
            }
            #expect(
                TabSelectionMath.index(forMenuTag: entry.tag, tabCount: tabCount) == index,
                "tag \(entry.tag) should resolve back to index \(index)"
            )
        }
    }
}

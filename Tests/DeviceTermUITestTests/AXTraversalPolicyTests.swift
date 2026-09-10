// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import DeviceTermUITest

/// The dump must not traverse the Apple menu's contents, and the input driver
/// must not match the menu or its descendants. Neither walk may descend into a
/// nested application element either. Both walks apply these rules, so allowing
/// a target neither puts Apple-menu actions within reach of a press nor lets a
/// self-nesting target consume the walk.
@Suite("traversal policy")
struct AXTraversalPolicyTests {
    /// The leading menu-bar item is the Apple menu, whatever it is called on a
    /// localized system, so position decides rather than title.
    @Test
    func refusesTheLeadingMenuBarItem() {
        #expect(!AXTraversalPolicy.shouldEnter(role: "AXMenuBarItem", siblingIndex: 0))
    }

    /// The target's own menus sit after it and must stay reachable: the
    /// playbook drives Shell > Mirror Physical Device… through this path.
    @Test
    func admitsTheTargetsOwnMenuBarItems() {
        for index in 1...5 {
            #expect(AXTraversalPolicy.shouldEnter(role: "AXMenuBarItem", siblingIndex: index))
        }
    }

    /// Only a menu-bar item is system-owned by position. A window or button
    /// that happens to be a first child is ordinary UI.
    @Test
    func admitsAFirstChildThatIsNotAMenuBarItem() {
        #expect(AXTraversalPolicy.shouldEnter(role: "AXWindow", siblingIndex: 0))
        #expect(AXTraversalPolicy.shouldEnter(role: "AXButton", siblingIndex: 0))
    }

    /// A role that would not read must not become a way past the rule: the
    /// leading child is where the Apple menu sits, and an unreadable role
    /// cannot rule it out.
    @Test
    func refusesALeadingChildWhoseRoleIsUnknown() {
        #expect(!AXTraversalPolicy.shouldEnter(role: nil, siblingIndex: 0))
    }

    /// Only the leading position is guarded, so an unreadable role deeper in
    /// the bar does not silently prune the target's own menus.
    @Test
    func admitsALaterChildWhoseRoleIsUnknown() {
        #expect(AXTraversalPolicy.shouldEnter(role: nil, siblingIndex: 1))
    }

    /// An application element never legitimately contains another. The caller
    /// never offers the root here, so seeing this role at all means one sits
    /// above it, and position is irrelevant: the observed shape puts the
    /// nested element first, but nothing guarantees that.
    @Test("refuses a nested application wherever it sits", arguments: 0...3)
    func refusesANestedApplication(index: Int) {
        #expect(!AXTraversalPolicy.shouldEnter(role: "AXApplication", siblingIndex: index))
    }

    /// A later position isolates the role rule. The leading-child guard cannot
    /// stand in for it even at index 0: that guard asks only whether the
    /// leading child is a menu-bar item, so it admits every other known role,
    /// a nested application included.
    @Test
    func refusesANestedApplicationForItsRoleRatherThanItsPosition() {
        #expect(!AXTraversalPolicy.shouldEnter(role: "AXApplication", siblingIndex: 9))
        #expect(AXTraversalPolicy.shouldEnter(role: "AXWindow", siblingIndex: 9))
    }
}

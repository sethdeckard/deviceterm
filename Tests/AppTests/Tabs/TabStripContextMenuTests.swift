// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// Structural assertions on the tab strip right-click menu. Same
/// shape as SimulatorPaneContextMenuTests / TerminalPaneContextMenuTests:
/// pin item order + selector wiring + state-driven affordances so a
/// rename or accidental drop trips here before the user hits a no-op
/// menu slot.
@MainActor
struct TabStripContextMenuTests {
    private func menu(
        isProtected: Bool = false,
        isOnlyTab: Bool = false,
        isLastTab: Bool = false,
        target: AnyObject? = nil
    ) -> NSMenu {
        makeTabStripContextMenu(
            for: TabID(value: 42),
            isEffectivelyProtected: isProtected,
            isOnlyTab: isOnlyTab,
            isLastTab: isLastTab,
            target: target
        )
    }

    /// `NSMenu.autoenablesItems` defaults to true, which re-derives
    /// each item's enabled state from the responder chain at display
    /// time, silently overriding any `item.isEnabled = false` the
    /// factory sets. The strip handlers don't `validateMenuItem`, so
    /// AppKit would re-enable "Close Other Tabs" / "Close Tabs to
    /// the Right" on a single-tab window despite our manual disable.
    /// Pin opt-out so this gotcha can't regress.
    @Test
    func autoenablesItemsIsOff() {
        #expect(menu().autoenablesItems == false)
    }

    @Test
    func contextMenuHasExpectedItemsInOrder() {
        let titles = menu().items.map(\.title)
        #expect(titles == [
            "Rename Tab…",
            "Protect Tab",
            "",  // separator
            "Duplicate Tab",
            "",  // separator
            "New Tab",
            "Open Automation Tab",
            "",  // separator
            "Close Tab",
            "Close Other Tabs",
            "Close Tabs to the Right"
        ])
    }

    /// Every item gets an EXPLICIT target rather than dispatching
    /// through the responder chain, because the strip VC is a sibling of
    /// the focused pane's VC, not an ancestor, so a chain walk from
    /// a focused terminal / sim pane never reaches the strip. Verify
    /// the target is wired and not nil.
    @Test
    func everyItemHasExplicitTarget() {
        final class Sink {}
        let sink = Sink()
        let menu = menu(target: sink)
        for item in menu.items where !item.isSeparatorItem {
            #expect(
                item.target === sink,
                "\(item.title) should target the explicit object"
            )
            #expect(
                item.action != nil,
                "\(item.title) is missing an action"
            )
        }
    }

    @Test
    func everyItemCarriesTheTabIDInRepresentedObject() {
        for item in menu().items where !item.isSeparatorItem {
            #expect(
                item.representedObject as? TabID == TabID(value: 42),
                "\(item.title) is missing the TabID"
            )
        }
    }

    @Test
    func itemsRouteToTabStripViewControllerSelectors() {
        let expected: [(String, Selector)] = [
            ("Rename Tab…", #selector(TabStripViewController.renameTabFromMenu(_:))),
            ("Protect Tab", #selector(TabStripViewController.toggleProtectionFromMenu(_:))),
            ("Duplicate Tab", #selector(TabStripViewController.duplicateTabFromMenu(_:))),
            ("New Tab", #selector(TabStripViewController.newTabFromMenu(_:))),
            (
                "Open Automation Tab",
                #selector(TabStripViewController.openAutomationTabFromMenu(_:))
            ),
            ("Close Tab", #selector(TabStripViewController.closeTabFromMenu(_:))),
            (
                "Close Other Tabs",
                #selector(TabStripViewController.closeOtherTabsFromMenu(_:))
            ),
            (
                "Close Tabs to the Right",
                #selector(TabStripViewController.closeTabsToRightFromMenu(_:))
            )
        ]
        let items = menu().items
        for (title, selector) in expected {
            guard let item = items.first(where: { $0.title == title }) else {
                Issue.record("context menu missing \(title)")
                continue
            }
            #expect(item.action == selector, "wrong action on \(title)")
        }
    }

    @Test
    func protectionItemTitleFlipsWhenAlreadyProtected() {
        let menu = menu(isProtected: true)
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Unprotect Tab"))
        #expect(!titles.contains("Protect Tab"))
        let protectionItem = menu.items.first { $0.title == "Unprotect Tab" }
        #expect(protectionItem?.state == .on)
    }

    @Test
    func protectionItemIsOffWhenTabIsUnprotected() {
        let protectionItem = menu(isProtected: false).items.first { $0.title == "Protect Tab" }
        #expect(protectionItem?.state == .off)
    }

    @Test
    func closeOtherTabsDisabledWhenOnlyTab() {
        let menu = menu(isOnlyTab: true)
        let closeOthers = menu.items.first { $0.title == "Close Other Tabs" }
        #expect(closeOthers?.isEnabled == false)
    }

    @Test
    func closeOtherTabsEnabledWithSiblings() {
        let menu = menu(isOnlyTab: false)
        let closeOthers = menu.items.first { $0.title == "Close Other Tabs" }
        #expect(closeOthers?.isEnabled == true)
    }

    @Test
    func closeTabsToRightDisabledWhenLastTab() {
        let menu = menu(isLastTab: true)
        let closeRight = menu.items.first { $0.title == "Close Tabs to the Right" }
        #expect(closeRight?.isEnabled == false)
    }

    @Test
    func closeTabsToRightEnabledWhenTabsFollow() {
        let menu = menu(isLastTab: false)
        let closeRight = menu.items.first { $0.title == "Close Tabs to the Right" }
        #expect(closeRight?.isEnabled == true)
    }
}

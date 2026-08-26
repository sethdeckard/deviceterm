// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// Structural assertions on the terminal pane right-click menu. Same
/// shape as SimulatorPaneContextMenuTests: pin item order + selector
/// wiring so a rename or accidental drop trips here before the user
/// hits a no-op menu slot.
@MainActor
struct TerminalPaneContextMenuTests {
    @Test
    func contextMenuHasExpectedItemsInOrder() {
        let menu = makeTerminalPaneContextMenu()
        let titles = menu.items.map(\.title)
        #expect(titles == [
            "Copy",
            "Paste",
            "",  // separator
            "Clear",
            "",  // separator
            "Open in New Tab",
            "Split Right",
            "Split Down",
            "",  // separator
            "Mirror Physical Device…",
            "",  // separator
            "Close Pane"
        ])
    }

    @Test
    func everyItemTargetsTheResponderChain() {
        for item in makeTerminalPaneContextMenu().items where !item.isSeparatorItem {
            #expect(
                item.target == nil,
                "\(item.title) should use the responder chain (nil target)"
            )
            #expect(
                item.action != nil,
                "\(item.title) is missing an action"
            )
        }
    }

    @Test
    func itemsRouteToTerminalPaneVCSelectors() {
        let expected: [(String, Selector)] = [
            ("Copy", #selector(TerminalPaneViewController.copy(_:))),
            ("Paste", #selector(TerminalPaneViewController.paste(_:))),
            ("Clear", #selector(TerminalPaneViewController.clearTerminalScreen(_:))),
            (
                "Open in New Tab",
                #selector(TerminalPaneViewController.openCurrentInNewTab(_:))
            ),
            (
                "Split Right",
                #selector(TerminalPaneViewController.splitTerminalRight(_:))
            ),
            (
                "Split Down",
                #selector(TerminalPaneViewController.splitTerminalDown(_:))
            ),
            (
                "Mirror Physical Device…",
                #selector(AppDelegate.mirrorPhysicalDevice(_:))
            ),
            (
                "Close Pane",
                #selector(TerminalPaneViewController.closeTerminalPaneViaMenu(_:))
            )
        ]
        let items = makeTerminalPaneContextMenu().items
        for (title, selector) in expected {
            guard let item = items.first(where: { $0.title == title }) else {
                Issue.record("context menu missing \(title)")
                continue
            }
            #expect(item.action == selector, "wrong action on \(title)")
        }
    }
}

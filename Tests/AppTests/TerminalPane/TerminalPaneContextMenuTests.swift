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
    /// Titles whose chord is mirrored from the catalog, paired with the row
    /// they mirror. Every other item deliberately carries none.
    ///
    /// Open in New Tab is absent on purpose: it creates a fresh tab seeded
    /// with the source tab's latest cwd, where ⌘T's `.newTab` opens an empty
    /// one. Close Pane uses a separate selector; both paths request tab
    /// closure for the last terminal.
    private static let mirrored: [(title: String, action: KeybindingAction)] = [
        ("Copy", .copy),
        ("Paste", .paste),
        ("Clear", .clearBuffer),
        ("Split Right", .splitRight),
        ("Split Down", .splitDown)
    ]

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

    /// Reads the chord back off the built item and compares it to the catalog
    /// row rather than restating "⌘D" here, so retuning a shortcut moves this
    /// assertion with it instead of breaking it.
    @Test
    func mirroredItemsCarryTheirCatalogChord() {
        let items = makeTerminalPaneContextMenu().items
        for (title, action) in Self.mirrored {
            guard let item = items.first(where: { $0.title == title }) else {
                Issue.record("context menu missing \(title)")
                continue
            }
            let built = KeyChord(menuItem: item)
            // Both sides being nil would compare equal, so the presence of a
            // chord is asserted before the chord itself.
            #expect(built != nil, "\(title) should carry a shortcut")
            #expect(
                built == KeybindingCatalog.entry(for: action)?.chord,
                "wrong chord on \(title)"
            )
        }
    }

    @Test
    func unmirroredItemsCarryNoShortcut() {
        let mirroredTitles = Set(Self.mirrored.map(\.title))
        for item in makeTerminalPaneContextMenu().items
        where !item.isSeparatorItem && !mirroredTitles.contains(item.title) {
            #expect(
                item.keyEquivalent.isEmpty,
                "\(item.title) is excluded from mirroring and should carry no shortcut"
            )
        }
    }
}

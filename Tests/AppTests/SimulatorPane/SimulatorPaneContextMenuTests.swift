// SPDX-License-Identifier: GPL-3.0-or-later
//
// Structural assertions on the sim pane right-click menu. Same
// shape as MainMenuTests: pin the item ordering + selector wiring
// so a future rename or accidental drop trips here before the user
// hits a no-op menu slot.

@testable import App
import AppKit
import Testing

@MainActor
struct SimulatorPaneContextMenuTests {
    @Test
    func contextMenuHasExpectedItemsInOrder() {
        let menu = makeSimulatorPaneContextMenu()
        let titles = menu.items.map(\.title)
        #expect(titles == [
            "Home",
            "Lock",
            "Side Button",
            "Siri",
            "Apple Pay",
            "",  // separator
            "Crown Press",
            "Crown Rotate Up",
            "Crown Rotate Down",
            "",  // separator
            "Rotate Left",
            "Rotate Right",
            "Location",
            "",  // separator
            "Reboot",
            "Shut Down",
            "Erase All Content and Settings…",
            "",  // separator
            "Screenshot",
            "Record Screen",
            "",  // separator
            "Open in Simulator.app",
            "Reveal in Finder",
            "",  // separator
            "Mirror Physical Device…",
            "",  // separator
            "Close Pane"
        ])
    }

    @Test
    func everyItemTargetsTheResponderChain() {
        for item in makeSimulatorPaneContextMenu().items where !item.isSeparatorItem {
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
    func itemsRouteToSimulatorPaneVCSelectors() {
        let expected: [(String, Selector)] = [
            ("Home", #selector(SimulatorPaneViewController.pressHardwareHome(_:))),
            ("Lock", #selector(SimulatorPaneViewController.pressHardwareLock(_:))),
            ("Side Button", #selector(SimulatorPaneViewController.pressHardwareSide(_:))),
            ("Siri", #selector(SimulatorPaneViewController.pressHardwareSiri(_:))),
            ("Apple Pay", #selector(SimulatorPaneViewController.pressHardwareApplePay(_:))),
            (
                "Crown Press",
                #selector(SimulatorPaneViewController.pressDigitalCrown(_:))
            ),
            (
                "Crown Rotate Up",
                #selector(SimulatorPaneViewController.rotateCrownUp(_:))
            ),
            (
                "Crown Rotate Down",
                #selector(SimulatorPaneViewController.rotateCrownDown(_:))
            ),
            ("Rotate Left", #selector(SimulatorPaneViewController.rotateDeviceLeft(_:))),
            ("Rotate Right", #selector(SimulatorPaneViewController.rotateDeviceRight(_:))),
            ("Reboot", #selector(SimulatorPaneViewController.rebootDevice(_:))),
            ("Shut Down", #selector(SimulatorPaneViewController.shutDownSim(_:))),
            (
                "Erase All Content and Settings…",
                #selector(SimulatorPaneViewController.eraseAllContent(_:))
            ),
            ("Screenshot", #selector(SimulatorPaneViewController.screenshotPane(_:))),
            ("Record Screen", #selector(SimulatorPaneViewController.recordPane(_:))),
            (
                "Open in Simulator.app",
                #selector(SimulatorPaneViewController.openInSimulatorApp(_:))
            ),
            ("Reveal in Finder", #selector(SimulatorPaneViewController.revealInFinder(_:))),
            (
                "Mirror Physical Device…",
                #selector(AppDelegate.mirrorPhysicalDevice(_:))
            ),
            ("Close Pane", #selector(SimulatorPaneViewController.closePane(_:)))
        ]
        let items = makeSimulatorPaneContextMenu().items
        for (title, selector) in expected {
            guard let item = items.first(where: { $0.title == title }) else {
                Issue.record("context menu missing \(title)")
                continue
            }
            #expect(item.action == selector, "wrong action on \(title)")
        }
    }
}

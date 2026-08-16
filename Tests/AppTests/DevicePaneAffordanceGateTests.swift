// SPDX-License-Identifier: GPL-3.0-or-later
//
// DevicePaneAffordanceGateTests: proves the device-pane affordance
// gate is wired end to end at the two surfaces a test can reach without
// a window: the focused VC's `validateUserInterfaceItem` (context /
// main menu) and the chrome ribbon's `ribbonActions`. A device pane
// disables the simulator-only actions and surfaces only buttons +
// rotation; a sim pane is unaffected.

@testable import App
import AppKit
import DaemonProtocol
import Testing

@MainActor
struct DevicePaneAffordanceGateTests {
    private let deviceCaps = PaneCapabilities(
        touch: true,
        key: true,
        text: true,
        button: true,
        rotate: true,
        crown: false,
        accessibility: false,
        location: true
    )

    private func deviceVC() -> SimulatorPaneViewController {
        SimulatorPaneViewController(
            mirroredPane: DevicePaneState(
                paneId: "dp1",
                deviceId: "fd00::1",
                displayName: "iPhone 16 Pro",
                family: DeviceFamily.unknown.rawValue,
                capabilities: deviceCaps
            ),
            daemonClient: FakeDaemonClient(),
            advisory: .silent()
        )
    }

    private func simVC() -> SimulatorPaneViewController {
        SimulatorPaneViewController(
            simPane: SimPaneState(
                paneId: "p1",
                udid: "U",
                displayName: "iPhone 17 Pro",
                family: "phone"
            ),
            daemonClient: FakeDaemonClient(),
            advisory: .silent()
        )
    }

    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "x", action: action, keyEquivalent: "")
    }

    @Test("a device VC disables simulator-only menu actions")
    func deviceVCDisablesSimulatorOnlyActions() {
        let viewController = deviceVC()
        #expect(viewController.isPhysicalDevice)
        for selector in [
            #selector(SimulatorPaneViewController.eraseAllContent(_:)),
            #selector(SimulatorPaneViewController.shutDownSim(_:)),
            #selector(SimulatorPaneViewController.openInSimulatorApp(_:)),
            #selector(SimulatorPaneViewController.revealInFinder(_:)),
            #selector(SimulatorPaneViewController.installApp(_:)),
            #selector(SimulatorPaneViewController.rebootDevice(_:)),
            #selector(SimulatorPaneViewController.screenshotPane(_:)),
            #selector(SimulatorPaneViewController.recordPane(_:)),
            #selector(SimulatorPaneViewController.pressHardwareApplePay(_:)),
            #selector(SimulatorPaneViewController.pressDigitalCrown(_:)),
            #selector(SimulatorPaneViewController.toggleAxInspector(_:))
        ] {
            #expect(
                !viewController.validateUserInterfaceItem(menuItem(selector)),
                "expected \(selector) disabled on a device pane"
            )
        }
    }

    @Test("a device VC keeps buttons + rotation enabled")
    func deviceVCKeepsButtonsAndRotation() {
        let viewController = deviceVC()
        for selector in [
            #selector(SimulatorPaneViewController.pressHardwareHome(_:)),
            #selector(SimulatorPaneViewController.pressHardwareLock(_:)),
            #selector(SimulatorPaneViewController.pressHardwareSide(_:)),
            #selector(SimulatorPaneViewController.pressHardwareSiri(_:)),
            #selector(SimulatorPaneViewController.rotateDeviceLeft(_:)),
            #selector(SimulatorPaneViewController.rotateDeviceRight(_:))
        ] {
            #expect(
                viewController.validateUserInterfaceItem(menuItem(selector)),
                "expected \(selector) enabled on a device pane"
            )
        }
        // Close Pane is universal, never gated.
        #expect(viewController.validateUserInterfaceItem(
            menuItem(#selector(SimulatorPaneViewController.closePane(_:)))
        ))
    }

    @Test("a sim VC keeps the simulator-only actions enabled")
    func simVCKeepsSimulatorActions() {
        let viewController = simVC()
        #expect(!viewController.isPhysicalDevice)
        for selector in [
            #selector(SimulatorPaneViewController.eraseAllContent(_:)),
            #selector(SimulatorPaneViewController.openInSimulatorApp(_:)),
            #selector(SimulatorPaneViewController.pressHardwareApplePay(_:)),
            #selector(SimulatorPaneViewController.screenshotPane(_:))
        ] {
            #expect(
                viewController.validateUserInterfaceItem(menuItem(selector)),
                "expected \(selector) enabled on a sim pane"
            )
        }
    }

    @Test("the device chrome ribbon shows only buttons + rotation")
    func deviceRibbonIsButtonsAndRotation() {
        let viewModel = PaneChromeViewModel(
            family: DeviceFamily.unknown.rawValue,
            capabilities: deviceCaps,
            isPhysicalDevice: true
        )
        #expect(Set(viewModel.ribbonActions) == [
            .rotateLeft, .rotateRight, .home, .lock, .side, .siri
        ])
        // No simulator-only / no-hardware controls leak in.
        #expect(!viewModel.ribbonActions.contains(.screenshot))
        #expect(!viewModel.ribbonActions.contains(.record))
        #expect(!viewModel.ribbonActions.contains(.axInspector))
        #expect(!viewModel.ribbonActions.contains(.applePay))
        // The collapsed-ribbon default is a hardware button, not the
        // sim-only screenshot the unknown-family default would pick.
        #expect(viewModel.lastUsedAction == .home)
    }

    @Test("the sim phone chrome ribbon keeps its full row")
    func simPhoneRibbonKeepsFullRow() {
        let viewModel = PaneChromeViewModel(
            family: "phone",
            capabilities: .simulator,
            isPhysicalDevice: false
        )
        #expect(viewModel.ribbonActions == [
            .home, .screenshot, .record, .rotateLeft, .rotateRight,
            .axInspector, .lock, .side, .siri, .applePay
        ])
    }
}

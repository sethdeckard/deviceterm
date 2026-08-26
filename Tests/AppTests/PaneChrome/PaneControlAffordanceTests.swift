// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import Testing

/// The shared affordance gate that keeps
/// the three control surfaces (context menu, main menu, chrome ribbon)
/// from drifting. A simulator reports the full capability set so every
/// action its family supports stays enabled; a physical device is
/// trimmed to buttons + rotation, with the simulator-only housekeeping /
/// capture / Apple Pay / crown / AX actions disabled.
@MainActor
struct PaneControlAffordanceTests {
    /// A physical-device capability set: touch + keyboard + buttons +
    /// rotate are live; no crown (no hardware) and no accessibility (no
    /// AX service).
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

    @Test("a phone simulator keeps every non-crown affordance")
    func simulatorPhoneEnablesEverythingButCrown() {
        let caps = PaneCapabilities.simulator
        for affordance in [
            PaneControlAffordance.button,
            .touch,
            .applePay,
            .rotate,
            .capture,
            .accessibility,
            .simulatorHousekeeping
        ] {
            #expect(affordance.isEnabled(
                capabilities: caps,
                isPhysicalDevice: false,
                family: .phone
            ))
        }
        // Crown is watch-only even on a sim (a phone has no crown).
        #expect(!PaneControlAffordance.crown.isEnabled(
            capabilities: caps,
            isPhysicalDevice: false,
            family: .phone
        ))
    }

    @Test("a watch simulator enables crown")
    func simulatorWatchEnablesCrown() {
        #expect(PaneControlAffordance.crown.isEnabled(
            capabilities: .simulator,
            isPhysicalDevice: false,
            family: .watch
        ))
    }

    /// Location is gated on the capability flag alone, with no family
    /// term. This test fails if a family gate copied from `.crown` is
    /// ever added.
    @Test("location is enabled on every simulator family", arguments: [
        DeviceFamily.phone, .pad, .watch, .tv, .unknown
    ])
    func locationIgnoresFamily(family: DeviceFamily) {
        #expect(PaneControlAffordance.location.isEnabled(
            capabilities: .simulator,
            isPhysicalDevice: false,
            family: family
        ))
    }

    /// A physical device mirrors the same rule: the flag decides, not
    /// the kind of pane.
    @Test("location follows the capability flag on a device pane")
    func locationFollowsCapabilityOnDevice() {
        #expect(PaneControlAffordance.location.isEnabled(
            capabilities: deviceCaps, isPhysicalDevice: true, family: .unknown
        ))
        var withoutLocation = deviceCaps
        withoutLocation.location = false
        #expect(!PaneControlAffordance.location.isEnabled(
            capabilities: withoutLocation, isPhysicalDevice: true, family: .unknown
        ))
    }

    /// Every way into the submenu is gated. Missing one would leave a
    /// device with no location support still offering a way to a
    /// position it cannot take: the sheet types one, Use My Location
    /// takes one from the Mac, a `.gpx` row walks one.
    @Test("every location selector maps to the location affordance", arguments: [
        #selector(SimulatorPaneViewController.applySimulatedLocation(_:)),
        #selector(SimulatorPaneViewController.useMyLocation(_:)),
        #selector(SimulatorPaneViewController.applyRouteFile(_:)),
        #selector(SimulatorPaneViewController.showCustomCoordinates(_:))
    ])
    func locationSelectorsMapToAffordance(selector: Selector) {
        #expect(PaneControlAffordance.forSelector(selector) == .location)
    }

    @Test("a physical device keeps buttons + rotation + App Switcher")
    func physicalDeviceTrimsToButtonsAndRotation() {
        // Supported on the device.
        #expect(PaneControlAffordance.button.isEnabled(
            capabilities: deviceCaps, isPhysicalDevice: true, family: .unknown
        ))
        #expect(PaneControlAffordance.rotate.isEnabled(
            capabilities: deviceCaps, isPhysicalDevice: true, family: .unknown
        ))
        // App Switcher (`.touch`) is honored on the device: the backend emits a
        // plain bottom-edge swipe its real digitizer + SpringBoard recognize.
        #expect(PaneControlAffordance.touch.isEnabled(
            capabilities: deviceCaps, isPhysicalDevice: true, family: .unknown
        ))
        // Simulator-only / not-yet-wired / no hardware → all disabled.
        #expect(!PaneControlAffordance.applePay.isEnabled(
            capabilities: deviceCaps, isPhysicalDevice: true, family: .unknown
        ))
        #expect(!PaneControlAffordance.capture.isEnabled(
            capabilities: deviceCaps, isPhysicalDevice: true, family: .unknown
        ))
        #expect(!PaneControlAffordance.accessibility.isEnabled(
            capabilities: deviceCaps, isPhysicalDevice: true, family: .unknown
        ))
        #expect(!PaneControlAffordance.simulatorHousekeeping.isEnabled(
            capabilities: deviceCaps, isPhysicalDevice: true, family: .unknown
        ))
        #expect(!PaneControlAffordance.crown.isEnabled(
            capabilities: deviceCaps, isPhysicalDevice: true, family: .unknown
        ))
    }

    @Test("button affordance follows the capability flag")
    func buttonAffordanceFollowsCapability() {
        var caps = deviceCaps
        caps.button = false
        #expect(!PaneControlAffordance.button.isEnabled(
            capabilities: caps, isPhysicalDevice: true, family: .unknown
        ))
    }

    @Test("device App Switcher needs only touch, not the Home button")
    func deviceAppSwitcherRequiresOnlyTouch() {
        // The device realization is a system-gesture touch swipe
        // (`openAppSwitcher`, always wired over the human-input channel), with
        // the Home double-press as a fallback, so a device with no hardware
        // buttons (button == false) still opens the App Switcher via the swipe,
        // as long as it reports touch.
        var caps = deviceCaps
        caps.button = false
        #expect(caps.touch)
        #expect(PaneControlAffordance.touch.isEnabled(
            capabilities: caps, isPhysicalDevice: true, family: .unknown
        ))
    }

    @Test("selector mapping routes the sim-only group to housekeeping")
    func selectorMappingIsCorrect() {
        #expect(PaneControlAffordance.forSelector(
            #selector(SimulatorPaneViewController.pressHardwareHome(_:))
        ) == .button)
        #expect(PaneControlAffordance.forSelector(
            #selector(SimulatorPaneViewController.pressHardwareApplePay(_:))
        ) == .applePay)
        #expect(PaneControlAffordance.forSelector(
            #selector(SimulatorPaneViewController.rotateDeviceLeft(_:))
        ) == .rotate)
        #expect(PaneControlAffordance.forSelector(
            #selector(SimulatorPaneViewController.pressDigitalCrown(_:))
        ) == .crown)
        #expect(PaneControlAffordance.forSelector(
            #selector(SimulatorPaneViewController.recordPane(_:))
        ) == .capture)
        #expect(PaneControlAffordance.forSelector(
            #selector(SimulatorPaneViewController.toggleAxInspector(_:))
        ) == .accessibility)
        for selector in [
            #selector(SimulatorPaneViewController.eraseAllContent(_:)),
            #selector(SimulatorPaneViewController.shutDownSim(_:)),
            #selector(SimulatorPaneViewController.openInSimulatorApp(_:)),
            #selector(SimulatorPaneViewController.revealInFinder(_:)),
            #selector(SimulatorPaneViewController.installApp(_:)),
            #selector(SimulatorPaneViewController.rebootDevice(_:))
        ] {
            #expect(PaneControlAffordance.forSelector(selector) == .simulatorHousekeeping)
        }
    }

    @Test("an ungated selector returns nil so the caller keeps its default")
    func ungatedSelectorReturnsNil() {
        #expect(PaneControlAffordance.forSelector(
            #selector(SimulatorPaneViewController.closePane(_:))
        ) == nil)
        #expect(!PaneControlAffordance.gates(
            #selector(SimulatorPaneViewController.closePane(_:))
        ))
    }

    @Test("chrome-action mapping is total and matches the selector groups")
    func chromeActionMapping() {
        #expect(PaneControlAffordance.forChromeAction(.home) == .button)
        #expect(PaneControlAffordance.forChromeAction(.applePay) == .applePay)
        #expect(PaneControlAffordance.forChromeAction(.rotateLeft) == .rotate)
        #expect(PaneControlAffordance.forChromeAction(.crownUp) == .crown)
        #expect(PaneControlAffordance.forChromeAction(.screenshot) == .capture)
        #expect(PaneControlAffordance.forChromeAction(.record) == .capture)
        #expect(PaneControlAffordance.forChromeAction(.axInspector) == .accessibility)
    }
}

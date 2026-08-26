// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol

/// The single source of truth for whether a
/// device-control affordance is available on a given pane, shared by the
/// three surfaces that expose those controls: the right-click context
/// menu + main menu (both validated through `validateUserInterfaceItem`
/// on the focused `SimulatorPaneViewController` and the
/// `PaneLayoutViewController` fallback) and the on-pane chrome ribbon
/// (`PaneChromeViewModel.ribbonActions`). Factoring the rule here keeps
/// the surfaces from drifting: a control disabled in one place is
/// disabled in all.
///
/// A pane mirrors either a CoreSimulator (every control supported) or a
/// physically-connected device (a capability subset). The gate reads the
/// per-pane `PaneCapabilities` for the input-verb families (buttons,
/// rotation, crown, accessibility) and falls back to "is this a
/// simulator" for the housekeeping actions that have no physical-device
/// equivalent (Erase / Shut Down / Open in Simulator / Reveal in Finder
/// / Apple Pay) or that the physical-device backend does not support
/// (Reboot / Screenshot
/// / Record / Install). Sim panes report the full capability set, so the
/// gate is a no-op for them; it only ever subtracts affordances from a
/// device pane.
@MainActor
enum PaneControlAffordance: Equatable {
    /// Hardware buttons Home / Lock / Side / Siri (`capabilities.button`).
    case button
    /// Synthesized touch gestures with no hardware button: App Switcher
    /// (swipe-up-and-dwell), gated on `capabilities.touch`.
    case touch
    /// Apple Pay, simulator-only (Device Hub omits it; a real payment
    /// flow isn't simulable on hardware), even though a device reports
    /// `button` support for the other hardware keys.
    case applePay
    /// Device orientation Rotate Left / Right (`capabilities.rotate`).
    case rotate
    /// Watch Digital Crown: `capabilities.crown` AND a watch family (a
    /// phone sim reports crown-capable but has no crown; a device
    /// reports crown:false).
    case crown
    /// Screenshot / Record, simulator-only. There is no device
    /// path; grabbing or recording the in-process mirror is not
    /// implemented.
    case capture
    /// AX inspector, gated on `capabilities.accessibility` (no physical-device
    /// AX service).
    case accessibility
    /// Simulated GPS position: gated only by `capabilities.location`.
    /// Backend capability, not device family, decides availability.
    /// Unlike `.crown`, which is family-gated because a phone has no
    /// crown, there is no family that lacks a notion of location. A
    /// runtime that refuses should report `location: false` from its
    /// backend rather than be guessed at here.
    case location
    /// Reboot / Shut Down / Erase / Open in Simulator.app / Reveal in
    /// Finder / Install, simulator-only (no physical-device equivalent,
    /// or not yet wired). Never automation-reboots a device.
    case simulatorHousekeeping

    private static let buttonSelectors: Set<Selector> = [
        #selector(SimulatorPaneViewController.pressHardwareHome(_:)),
        #selector(SimulatorPaneViewController.pressHardwareLock(_:)),
        #selector(SimulatorPaneViewController.pressHardwareSide(_:)),
        #selector(SimulatorPaneViewController.pressHardwareSiri(_:))
    ]
    private static let rotateSelectors: Set<Selector> = [
        #selector(SimulatorPaneViewController.rotateDeviceLeft(_:)),
        #selector(SimulatorPaneViewController.rotateDeviceRight(_:))
    ]
    private static let crownSelectors: Set<Selector> = [
        #selector(SimulatorPaneViewController.pressDigitalCrown(_:)),
        #selector(SimulatorPaneViewController.rotateCrownUp(_:)),
        #selector(SimulatorPaneViewController.rotateCrownDown(_:))
    ]
    /// Every submenu path: picking a row, walking a saved `.gpx`,
    /// taking the Mac's own position, and opening the sheet that types
    /// one. Each has to be gated, or a device with no location support
    /// would still offer a way in.
    private static let locationSelectors: Set<Selector> = [
        #selector(SimulatorPaneViewController.applySimulatedLocation(_:)),
        #selector(SimulatorPaneViewController.applyRouteFile(_:)),
        #selector(SimulatorPaneViewController.useMyLocation(_:)),
        #selector(SimulatorPaneViewController.showCustomCoordinates(_:))
    ]
    private static let captureSelectors: Set<Selector> = [
        #selector(SimulatorPaneViewController.screenshotPane(_:)),
        #selector(SimulatorPaneViewController.recordPane(_:))
    ]
    private static let housekeepingSelectors: Set<Selector> = [
        #selector(SimulatorPaneViewController.rebootDevice(_:)),
        #selector(SimulatorPaneViewController.shutDownSim(_:)),
        #selector(SimulatorPaneViewController.eraseAllContent(_:)),
        #selector(SimulatorPaneViewController.openInSimulatorApp(_:)),
        #selector(SimulatorPaneViewController.revealInFinder(_:)),
        #selector(SimulatorPaneViewController.installApp(_:))
    ]

    /// Map a responder-chain selector to the affordance it represents,
    /// or `nil` when the selector isn't a gated device-control action
    /// (the caller leaves those at their own default). The record /
    /// screenshot selectors map to `.capture`; the housekeeping group
    /// maps to `.simulatorHousekeeping`.
    static func forSelector(_ action: Selector) -> PaneControlAffordance? {
        if buttonSelectors.contains(action) { return .button }
        if action == #selector(SimulatorPaneViewController.invokeAppSwitcher(_:)) {
            return .touch
        }
        if action == #selector(SimulatorPaneViewController.pressHardwareApplePay(_:)) {
            return .applePay
        }
        if rotateSelectors.contains(action) { return .rotate }
        if crownSelectors.contains(action) { return .crown }
        if captureSelectors.contains(action) { return .capture }
        if action == #selector(SimulatorPaneViewController.toggleAxInspector(_:)) {
            return .accessibility
        }
        if locationSelectors.contains(action) { return .location }
        if housekeepingSelectors.contains(action) { return .simulatorHousekeeping }
        return nil
    }

    /// Map a chrome-ribbon action to its affordance. Total (every
    /// `SimChromeAction` has a gate) so the ribbon can filter its
    /// family-ordered candidate list down to the available controls.
    static func forChromeAction(_ action: SimChromeAction) -> PaneControlAffordance {
        switch action {
        case .home, .lock, .side, .siri:
            return .button

        case .applePay:
            return .applePay

        case .rotateLeft, .rotateRight:
            return .rotate

        case .crownPress, .crownUp, .crownDown:
            return .crown

        case .screenshot, .record:
            return .capture

        case .axInspector:
            return .accessibility
        }
    }

    /// Whether `action` is a selector this gate manages, used by the
    /// menu validators to decide a no-targeted-pane case (gated → disabled,
    /// unmanaged → left at the caller's default).
    static func gates(_ action: Selector) -> Bool {
        forSelector(action) != nil
    }

    /// Whether this affordance is enabled for a pane with the given
    /// capabilities + kind + family. Sim panes (full capabilities,
    /// `isPhysicalDevice == false`) get `true` for everything their
    /// family supports; a device pane is trimmed to its capability set.
    func isEnabled(
        capabilities: PaneCapabilities,
        isPhysicalDevice: Bool,
        family: DeviceFamily
    ) -> Bool {
        switch self {
        case .button:
            return capabilities.button

        case .touch:
            // App Switcher rides `pane.input.edgeSwipe`, realized per backend,
            // and needs `touch` on both. Simulator: an `IndigoHIDEdge`-tagged
            // swipe. Physical device: an enriched system-gesture touch swipe
            // (`openAppSwitcher`) that SpringBoard's recognizer consumes,
            // always wired (universalhidservice, and a device pane always
            // mirrors so the auth gate holds), with a consumer-HID Home
            // double-press only as a fallback. So a device pane supports the
            // action whenever it reports `touch`, independent of the Home
            // `button` capability.
            return capabilities.touch

        case .applePay:
            return !isPhysicalDevice && capabilities.button

        case .rotate:
            return capabilities.rotate

        case .crown:
            return capabilities.crown && family == .watch

        case .capture:
            return !isPhysicalDevice

        case .accessibility:
            return capabilities.accessibility

        case .location:
            return capabilities.location

        case .simulatorHousekeeping:
            return !isPhysicalDevice
        }
    }
}

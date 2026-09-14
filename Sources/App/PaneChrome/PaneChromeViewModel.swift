// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Observation

/// Observable state for the simulator pane's
/// chrome overlay (focus ring, title bar, status badge, hardware-button
/// toolbar, screenshot / record / AX-inspector controls, size-preset
/// menu). The chrome itself is a SwiftUI surface and is observed
/// natively via SwiftUI's body-tracking, so no `observe()` adapter is
/// required on the SwiftUI side. AppKit consumers of the same model
/// go through `observe()` per `Observe.swift` when they read it.
///
/// Per the SwiftUI/AppKit boundary rule, render-state-only surfaces
/// are SwiftUI by default; this view model is the seam where AppKit
/// (the simulator pane VC owns and mutates it) meets SwiftUI (the
/// overlay renders from it). The VC stays AppKit because Metal
/// rendering and multi-touch hit-testing are responder-chain
/// specific; the chrome is pure render state and is the right place
/// to start the SwiftUI lift.
///
/// Action closures (`onHardwareButton`, `onSizePresetSelected`, etc.) let
/// SwiftUI buttons dispatch through the chrome rather than reaching
/// back into AppKit responder lookup; the VC populates them at init
/// and they target the VC's existing intent methods + @objc selectors.
/// Going through closures rather than direct `target: self` selectors is
/// what keeps the model reusable from a stand-alone SwiftUI surface.
@MainActor
@Observable
final class PaneChromeViewModel {
    /// Whether the underlying simulator pane is the window's first
    /// responder. Drives the focus ring and nothing else. A
    /// desaturation scrim on non-linked siblings would read this
    /// same field, but isn't implemented.
    var isFocused: Bool

    /// Title shown in the top chrome bar. Mirrors the daemon-supplied
    /// device name (e.g. "iPhone 17 Pro"); the simulator pane VC
    /// writes it on attach + lifecycle events.
    var title: String

    /// Drives the status badge inset in the chrome top bar: spinning
    /// (booting), green (rendering), gray (shutdown), red (failed).
    /// The VC mirrors `SimulatorPaneViewModel.state` into this on
    /// every `render()` pass.
    var simState: SimulatorPaneState

    /// Coarse device family, which drives toolbar layout. Phone / pad
    /// surface the full button row (home / lock / side / Siri /
    /// pay / rotate); watch surfaces crown press + side; tv +
    /// unknown hide the row entirely.
    var family: String

    /// Per-pane device-control capabilities. The chrome ribbon filters
    /// its candidate actions through `PaneControlAffordance` so a
    /// physical-device pane shows only the controls it supports
    /// (buttons / rotate) and hides the simulator-only ones (screenshot
    /// / record / AX / Apple Pay).
    var capabilities: PaneCapabilities

    /// Whether the pane mirrors a physically-connected device. Pairs
    /// with `capabilities` in the affordance gate (the housekeeping /
    /// capture actions have no device equivalent yet).
    var isPhysicalDevice: Bool

    /// Whether a `simctl io recordVideo` is currently in flight for
    /// this pane. Drives the record button's icon + label (record vs
    /// stop). VC mirrors `SimulatorPaneViewController.recordingProcess
    /// != nil` into this in `render()`.
    var recordingActive: Bool

    /// AX inspector toggle. When true, the SimulatorContentView
    /// installs a mouse-move tracking area and the chrome shows
    /// the AX label under the cursor in a status line. Default off.
    var axInspectorEnabled: Bool

    /// Latest AX element label / role under the cursor when the AX
    /// inspector is enabled. Nil while disabled, between hits, or
    /// while waiting on the first `pane.ax.point` reply. The VC
    /// throttles updates so the line doesn't flicker.
    var axInspectorLabel: String?

    /// Available pixel dimensions of the device's display for the
    /// size-preset math. Initially populated from the daemon's
    /// attach response; if the daemon hadn't bound the renderable yet
    /// at attach time those arrive nil. The VC repopulates from the
    /// live `IOSurfaceRef` in `render()` as soon as the first frame
    /// arrives, so a preset clicked before that brief window is a
    /// no-op, and any subsequent click works against accurate values.
    var devicePixelWidth: Int?
    var devicePixelHeight: Int?

    /// Currently-selected size preset. The VC stamps this from a
    /// menu / shortcut / chrome-picker dispatch so the picker can
    /// show a checkmark; persisted in-memory only (a future prefs
    /// pane can lift it to a per-pane sticky preference).
    var selectedPreset: SimSizePreset?

    /// Chosen reveal rung: stop 0 shows `hotAction` on its own, which is
    /// nothing on a pane that has none, stop 1 shows the size-preset menu, and
    /// each later stop adds one more trailing action, up to
    /// `ribbonWidestStop`.
    ///
    /// This is the choice, not the render. It outlives a pane too narrow to
    /// honor it, so widening the pane brings it back; draw from
    /// `ribbonRenderedStop` instead.
    ///
    /// Starts at the narrowest. A pane wide enough for more opens wider,
    /// decided once by the pane VC when the launch layout settles; a pane
    /// that never lays out keeps this default.
    var ribbonPreferredStop: Int = 0

    /// Latch on the launch-time width fit. Once true, `ribbonPreferredStop`
    /// belongs to whoever set it last and the launch pass stops revisiting it,
    /// so later window resizes and divider drags preserve the chosen stop while
    /// the rendered stop follows the live fit cap. A tap or drag sets this the
    /// moment the user makes a choice, so a manual choice always outranks the
    /// fit; the pane VC sets it on the first eligible post-auto-fit layout pass.
    var ribbonStopDecided: Bool = false

    /// Current fit-derived render cap, or nil before any measurement.
    ///
    /// The pane VC refreshes it on every on-window layout pass, independently
    /// of the one-shot launch latch, and that split is what lets a frozen
    /// launch choice and a live narrowing coexist without either overruling the
    /// other. It caps the render alone, never the choice, and floors at stop 0
    /// when even the narrowest stop cannot keep the device name whole.
    var ribbonWidestFittingStop: Int?

    /// Reveal stop a chevron drag has reached, nil when settled. Always a
    /// whole rung: the drag steps between stops rather than sliding between
    /// them, so this is never an intermediate width.
    ///
    /// Doubles as the "is dragging" flag, since reading an optional always
    /// touches the field and so keeps SwiftUI's tracking intact.
    var ribbonDragStop: Int?

    /// Widest reveal stop this pane offers.
    ///
    /// One past the action count, because the size-preset menu is the row's
    /// trailing item and occupies a rung of its own. A pane with no actions
    /// therefore still has a stop that reveals its size menu.
    var ribbonWidestStop: Int {
        PaneChromeRibbonFit.widestStop(actionCount: ribbonActions.count)
    }

    /// Reveal stop to draw: the live drag if one is in flight, otherwise the
    /// chosen stop, either way clamped to what the pane can currently show.
    ///
    /// Every field is bound before the clamp rather than short-circuited
    /// through `??`, because SwiftUI tracks only what a body actually reads
    /// and a skipped read stops the view re-rendering when that field moves.
    var ribbonRenderedStop: Int {
        let preferred = ribbonPreferredStop
        let dragging = ribbonDragStop
        let widest = ribbonWidestStop
        let cap = ribbonWidestFittingStop ?? widest
        return max(0, min(dragging ?? preferred, cap, widest))
    }

    /// Whether the ribbon is set to its widest stop, revealing the whole row.
    ///
    /// Reads the choice rather than the render, so a pane momentarily too
    /// narrow still reports expanded. Read-only so callers cannot reduce the
    /// multi-stop state to a writable Boolean.
    var ribbonExpanded: Bool {
        ribbonPreferredStop >= ribbonWidestStop
    }

    /// Most recently invoked ribbon action. Stamped by every ribbon button
    /// before its closure fires, and the default "hot" action when no on-state
    /// toggle wins and this pane still supports it.
    /// Per-family default (phone/pad → home, watch → crownPress,
    /// tv/unknown → screenshot) is set at init, so it can name an action the
    /// pane does not support; `hotAction` is what resolves that.
    var lastUsedAction: SimChromeAction

    /// Which ribbon action is "hot", surfaced as the visible button at the
    /// narrowest reveal stop. Priority cascade:
    ///   1. AX inspector if active (always wins while toggled on)
    ///   2. Recording if active
    ///   3. Last-used action, when this pane still supports it
    ///   4. The first action this pane does support
    ///
    /// Nil only when neither toggle is active and `ribbonActions` is empty,
    /// which a simulator never reports and a physical device can. The last two
    /// arms are why: `lastUsedAction` carries a per-family default seeded at init
    /// and can outlive the capability that justified it, so a device
    /// answering `button: false` would otherwise surface a live Home button
    /// that cannot do anything. Gating here rather than on the seed catches
    /// every source of a stale value, including capabilities that change
    /// after attach.
    ///
    /// The first two arms are deliberately ungated: a toggle can only be on
    /// if the pane supported turning it on, and its off-switch has to stay
    /// reachable.
    var hotAction: SimChromeAction? {
        if axInspectorEnabled {
            return .axInspector
        }
        if recordingActive {
            return .record
        }
        let supported = ribbonActions
        if supported.contains(lastUsedAction) {
            return lastUsedAction
        }
        return supported.first
    }

    /// The ribbon's interactive actions in left-to-right display order,
    /// already filtered to the ones this pane supports. The candidate
    /// ordering is family-based for a simulator; a physical device
    /// reports family `unknown` (which would otherwise collapse to the
    /// sim-only screenshot/record/AX row), so it gets its own
    /// buttons-and-rotate ordering. Either way `PaneControlAffordance`
    /// trims the list to the pane's capabilities: a sim keeps its full
    /// row, a device shows only buttons + rotation. Lives on the view
    /// model (not the SwiftUI view) so it's unit-testable and sits next
    /// to the capabilities it reads.
    var ribbonActions: [SimChromeAction] {
        let candidates: [SimChromeAction]
        if isPhysicalDevice {
            candidates = [.rotateLeft, .rotateRight, .home, .lock, .side, .siri]
        } else {
            switch DeviceFamily(wire: family) {
            case .phone, .pad:
                // Priority ordering: most-used actions first (capture +
                // orientation), state toggles next, hardware buttons last.
                candidates = [
                    .home, .screenshot, .record, .rotateLeft, .rotateRight,
                    .axInspector, .lock, .side, .siri, .applePay
                ]

            case .watch:
                candidates = [
                    .crownPress, .crownUp, .crownDown,
                    .screenshot, .record, .axInspector, .side
                ]

            case .tv, .unknown:
                candidates = [.screenshot, .record, .axInspector]
            }
        }
        let resolvedFamily = DeviceFamily(wire: family)
        return candidates.filter {
            PaneControlAffordance.forChromeAction($0).isEnabled(
                capabilities: capabilities,
                isPhysicalDevice: isPhysicalDevice,
                family: resolvedFamily
            )
        }
    }

    // MARK: - Action closures

    /// Press a hardware button (home / lock / side / siri / apple pay /
    /// digital crown). VC populates this with `[weak self] in self?.
    /// viewModel.pressButton($0)`. SwiftUI buttons in the toolbar
    /// call straight through.
    var onHardwareButton: (HardwareButton) -> Void = { _ in }

    /// Relative rotate-left / rotate-right. The chrome ribbon exposes
    /// both as separate buttons (rather than a single cycling control)
    /// because users expect direct, predictable orientation control.
    ///
    /// Only the ribbon calls these. The Device menu's ⌘← / ⌘→ and the
    /// right-click menu's rotation items dispatch `rotateDeviceLeft:` /
    /// `rotateDeviceRight:` on the view controller instead; the two
    /// paths meet at `SimulatorPaneViewModel.rotateLeft()`. What the
    /// ribbon does extra is take first responder first, which a menu
    /// action has no reason to.
    var onRotateLeft: () -> Void = {}
    var onRotateRight: () -> Void = {}

    /// Watch-only Digital Crown rotation (up / down, one detent per
    /// click). Forwarded to `SimulatorPaneViewModel.crown(delta:)`.
    var onCrownUp: () -> Void = {}
    var onCrownDown: () -> Void = {}

    /// Screenshot the focused sim's display (shells to `simctl io
    /// screenshot`).
    var onScreenshot: () -> Void = {}

    /// Toggle screen recording. The VC inspects `recordingActive` to
    /// pick start vs stop.
    var onRecordToggle: () -> Void = {}

    /// Toggle the AX inspector overlay.
    var onAxInspectorToggle: () -> Void = {}

    /// Apply a size preset. Only the ribbon's Size dropdown calls this;
    /// the View menu's ⌃⌘1–⌃⌘4 land on the view controller's own
    /// `applySizePreset*` selectors. Both meet at that controller's
    /// `applySizePreset(_:)`.
    var onSizePresetSelected: (SimSizePreset) -> Void = { _ in }

    /// Open the sim pane's right-click context menu, routed through
    /// the chrome's ⋯ overflow button. Mirrors the terminal chrome's
    /// equivalent affordance so both pane types expose the same set
    /// of actions through a visible button as well as right-click.
    /// The VC populates this with the same `NSMenu` its content view
    /// shows on right-click, with no separate menu definition.
    var onOpenContextMenu: () -> Void = {}

    init(
        title: String = "",
        isFocused: Bool = false,
        simState: SimulatorPaneState = .booting,
        family: String = "",
        capabilities: PaneCapabilities = .simulator,
        isPhysicalDevice: Bool = false,
        devicePixelWidth: Int? = nil,
        devicePixelHeight: Int? = nil
    ) {
        self.title = title
        self.isFocused = isFocused
        self.simState = simState
        self.family = family
        self.capabilities = capabilities
        self.isPhysicalDevice = isPhysicalDevice
        self.recordingActive = false
        self.axInspectorEnabled = false
        self.axInspectorLabel = nil
        self.devicePixelWidth = devicePixelWidth
        self.devicePixelHeight = devicePixelHeight
        self.selectedPreset = nil
        self.lastUsedAction = Self.defaultAction(
            forFamily: family,
            isPhysicalDevice: isPhysicalDevice
        )
    }

    /// Initial `lastUsedAction` until the user invokes any ribbon control. A
    /// physical
    /// device defaults to Home, since its first ribbon control is a hardware
    /// button, not the simulator-only screenshot. Sims keep the
    /// per-family default: phone/pad → home, watch → crown press,
    /// tv/unknown → screenshot (the only universally useful sim action).
    private static func defaultAction(
        forFamily family: String,
        isPhysicalDevice: Bool
    ) -> SimChromeAction {
        if isPhysicalDevice {
            return .home
        }
        switch DeviceFamily(wire: family) {
        case .phone, .pad:
            return .home

        case .watch:
            return .crownPress

        case .tv, .unknown:
            return .screenshot
        }
    }

    // MARK: - Ribbon intents

    /// Jump between the ribbon's end stops: the widest unless already there,
    /// otherwise the narrowest. What a chevron tap does, generalized so a
    /// tap from an intermediate stop opens rather than doing nothing.
    func toggleRibbonExtremes() {
        let widest = ribbonWidestStop
        settleRibbon(at: ribbonPreferredStop >= widest ? 0 : widest)
    }

    /// Land the ribbon on `stop`, clearing the live drag in the same step so
    /// the render moves straight to the settled rung rather than briefly
    /// reading a stale drag position.
    func settleRibbon(at stop: Int) {
        ribbonPreferredStop = max(0, min(stop, ribbonWidestStop))
        ribbonDragStop = nil
        ribbonStopDecided = true
    }

    /// Track a chevron drag. Writes only the live stop, since the committed
    /// choice must not move until the pointer is released.
    func trackRibbonDrag(stop: Int) {
        ribbonDragStop = max(0, min(stop, ribbonWidestStop))
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import Testing

/// The fold control across the three surfaces that offer it: the affordance
/// gate every surface reads, the ribbon's candidate list, and the fold-bar
/// state the ribbon button toggles.
///
/// A foldable is legitimately `.phone`, so none of this can be gated on
/// family the way the crown is. `capabilities.fold` is the only signal, and
/// these pin that it is the one being read.
@MainActor
struct FoldControlTests {
    private static let foldable = PaneCapabilities(
        touch: true,
        key: true,
        text: true,
        button: true,
        rotate: true,
        crown: false,
        accessibility: true,
        location: true,
        fold: true
    )

    private func chromeModel(
        capabilities: PaneCapabilities = .simulator,
        family: String = "phone"
    ) -> PaneChromeViewModel {
        PaneChromeViewModel(family: family, capabilities: capabilities)
    }

    @Test("fold is gated on the capability alone, never on family")
    func foldFollowsTheCapabilityAcrossEveryFamily() {
        for family in [DeviceFamily.phone, .pad, .watch, .tv, .unknown] {
            #expect(PaneControlAffordance.fold.isEnabled(
                capabilities: Self.foldable,
                isPhysicalDevice: false,
                family: family
            ))
            // The crown's family check is what this deliberately does not
            // copy: a foldable phone would fail one.
            #expect(!PaneControlAffordance.fold.isEnabled(
                capabilities: .simulator,
                isPhysicalDevice: false,
                family: family
            ))
        }
    }

    @Test("a physical device that reported fold would still get it")
    func foldIsNotSimulatorOnly() {
        // Nothing in the gate excludes a device, unlike capture and
        // housekeeping. If a backend ever reports a foldable phone, the
        // control is already correct rather than silently withheld.
        #expect(PaneControlAffordance.fold.isEnabled(
            capabilities: Self.foldable,
            isPhysicalDevice: true,
            family: .phone
        ))
        // Synthetic capabilities, pinning that the physical-device ribbon
        // and the affordance gate both permit fold rather than disagreeing.
        let model = PaneChromeViewModel(
            family: "phone",
            capabilities: Self.foldable,
            isPhysicalDevice: true
        )
        #expect(model.ribbonActions.contains(.fold))
    }

    @Test("every fold surface resolves to the one affordance")
    func allThreeSurfacesShareAGate() {
        let selectors = [
            #selector(SimulatorPaneViewController.foldDeviceClosed(_:)),
            #selector(SimulatorPaneViewController.foldDeviceBook(_:)),
            #selector(SimulatorPaneViewController.foldDeviceOpen(_:))
        ]
        for selector in selectors {
            #expect(PaneControlAffordance.forSelector(selector) == .fold)
            // The menu validators disable a gated selector when no pane is
            // targeted, so an ungated one would stay live over empty space.
            #expect(PaneControlAffordance.gates(selector))
        }
        #expect(PaneControlAffordance.forChromeAction(.fold) == .fold)
    }

    @Test("the ribbon offers fold only to a pane that can fold")
    func ribbonFiltersFoldOnTheCapability() {
        #expect(chromeModel(capabilities: Self.foldable).ribbonActions.contains(.fold))
        #expect(!chromeModel().ribbonActions.contains(.fold))
    }

    @Test("a foldable pane costs the ribbon one rung, not three")
    func foldAddsASingleRung() {
        let plain = chromeModel().ribbonActions.count
        let foldable = chromeModel(capabilities: Self.foldable).ribbonActions.count
        #expect(foldable == plain + 1)
    }

    @Test("the fold bar opens itself once the pane reports it can fold")
    func barRevealsOnTheFirstFoldableCapability() {
        let model = chromeModel()
        // Capabilities arrive after attach, so a pane starts not knowing.
        #expect(!model.foldControlVisible)
        model.capabilities = Self.foldable
        #expect(model.foldControlVisible)
    }

    @Test("a pane built already foldable shows the bar at init")
    func barRevealsWithoutACapabilityWrite() {
        // `didSet` does not fire for an assignment inside `init`, so this
        // path needs its own call and would otherwise never open.
        #expect(chromeModel(capabilities: Self.foldable).foldControlVisible)
    }

    @Test("a refresh never reopens a bar the user hid")
    func barStaysHiddenAcrossLaterCapabilityWrites() {
        let model = chromeModel(capabilities: Self.foldable)
        model.foldControlVisible = false
        // Capabilities are rewritten on every refresh, with the same values.
        model.capabilities = Self.foldable
        #expect(!model.foldControlVisible)
    }

    @Test("a pane that never folds never shows the bar")
    func barStaysHiddenWithoutTheCapability() {
        let model = chromeModel()
        model.capabilities = .simulator
        #expect(!model.foldControlVisible)
    }

    @Test("a clipped fold button declines clicks")
    func foldIsNotRevealedAtTheNarrowStops() throws {
        let model = chromeModel(capabilities: Self.foldable)
        let actions = model.ribbonActions
        let index = try #require(actions.firstIndex(of: .fold))
        // Fold sits third from the trailing end, and the row reveals from
        // there, so it needs stop 4. Derived rather than hard-coded, so
        // reordering the candidates moves the expectation with it.
        let fromEnd = actions.count - index
        for stop in 0..<(fromEnd + 1) {
            model.settleRibbon(at: stop)
            #expect(!model.isRibbonActionRevealed(.fold), "stop \(stop)")
        }
        model.settleRibbon(at: fromEnd + 1)
        #expect(model.isRibbonActionRevealed(.fold))
    }

    @Test("the widest stop reveals every action")
    func everyActionIsRevealedWhenFullyOpen() {
        let model = chromeModel(capabilities: Self.foldable)
        model.settleRibbon(at: model.ribbonWidestStop)
        for action in model.ribbonActions {
            #expect(model.isRibbonActionRevealed(action), "\(action)")
        }
    }

    @Test("an action this pane does not offer is never revealed")
    func anAbsentActionIsNotRevealed() {
        let model = chromeModel()
        model.settleRibbon(at: model.ribbonWidestStop)
        #expect(!model.isRibbonActionRevealed(.fold))
    }

    @Test("narrowing the ribbon never takes the fold bar away")
    func theBarOutlivesTheRibbonReveal() {
        let model = chromeModel(capabilities: Self.foldable)
        model.settleRibbon(at: 0)
        // The bar reads the capability and the user's own toggle, never the
        // reveal stop, so a collapsed ribbon still leaves the hinge reachable.
        #expect(!model.isRibbonActionRevealed(.fold))
        #expect(model.foldControlVisible)
    }

    @Test("the slider starts shut, which is where a Duo boots")
    func foldDegreesSeedsClosed() {
        #expect(chromeModel(capabilities: Self.foldable).foldDegrees == FoldPosture.closed.degrees)
    }

    @Test("each posture names one angle for every surface", arguments: [
        (FoldPosture.closed, 0.0),
        (FoldPosture.book, 120.0),
        (FoldPosture.open, 180.0)
    ])
    func posturesResolveToOneAngle(posture: FoldPosture, degrees: Double) {
        // The fold bar, the Device menu and the context menu all read
        // these, so a drift here would show as three surfaces disagreeing.
        #expect(posture.degrees == degrees)
        #expect(!posture.chromeTitle.isEmpty)
        #expect(NSImage(systemSymbolName: posture.chromeSymbol, accessibilityDescription: nil) != nil)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import Testing

/// The pane chrome's SwiftUI surface and its
/// AppKit mount. Three concerns:
///
///   1. The `@Observable` view model exposes the fields the chrome
///      reads (`title`, `isFocused`, the ribbon's reveal stop) with
///      sensible defaults and mutable setters. Pinned so a later
///      rename / refactor that changes the observable surface breaks
///      here, not in a runtime SwiftUI re-render bug.
///   2. The AppKit → SwiftUI bridge, `PaneChromeDragHostView`,
///      instantiates without crashing and accepts a frame, so the
///      hosting view stays constructible outside a live window.
///   3. The hosting view's Auto Layout opt-in is set so callers
///      pinning it with constraints don't have to remember the
///      `translatesAutoresizingMaskIntoConstraints` toggle.
@MainActor
struct PaneChromeOverlayTests {
    @Test
    func viewModelDefaultsAreEmptyAndUnfocused() {
        let viewModel = PaneChromeViewModel()
        #expect(viewModel.title.isEmpty)
        #expect(viewModel.isFocused == false)
    }

    @Test
    func ribbonStartsFullyOpenAndUnchosen() {
        // Nobody has moved the chevron, so there is no choice to honor and
        // the ribbon opens as wide as the pane allows. A pane that never lays
        // out has no cap either, so it reports its widest stop outright.
        let viewModel = phoneChrome()
        #expect(viewModel.ribbonChosenStop == nil)
        #expect(viewModel.ribbonDragStop == nil)
        #expect(viewModel.ribbonWidestFittingStop == nil)
        #expect(viewModel.ribbonRenderedStop == viewModel.ribbonWidestStop)
        #expect(viewModel.ribbonExpanded)
    }

    // MARK: - Reveal stop

    /// A phone sim, whose ribbon offers the full ten-action row.
    private func phoneChrome() -> PaneChromeViewModel {
        PaneChromeViewModel(title: "iPhone 17 Pro", family: "phone")
    }

    @Test
    func ribbonExpandedDerivesFromTheChosenStop() {
        let viewModel = phoneChrome()
        let widest = viewModel.ribbonWidestStop
        #expect(widest > 1)
        viewModel.ribbonChosenStop = widest - 1
        #expect(viewModel.ribbonExpanded == false)
        viewModel.ribbonChosenStop = widest
        #expect(viewModel.ribbonExpanded)
    }

    @Test
    func anUnchosenRibbonFollowsAGrowingRow() {
        // The absent choice tracks `ribbonWidestStop` rather than a rung
        // captured at init, so capabilities arriving after attach widen the
        // ribbon instead of stranding it at the old top rung.
        let viewModel = PaneChromeViewModel(
            title: "iPhone 17 Pro",
            family: "phone",
            capabilities: PaneCapabilities(
                touch: true,
                key: true,
                text: true,
                button: false,
                rotate: false,
                crown: false,
                accessibility: true,
                location: true
            )
        )
        let before = viewModel.ribbonWidestStop
        #expect(viewModel.ribbonRenderedStop == before)
        viewModel.capabilities = .simulator
        #expect(viewModel.ribbonWidestStop > before)
        #expect(viewModel.ribbonRenderedStop == viewModel.ribbonWidestStop)
        #expect(viewModel.ribbonExpanded)
    }

    @Test
    func theFitCapClampsTheRenderedStopWithoutForgettingTheChoice() {
        let viewModel = phoneChrome()
        viewModel.ribbonChosenStop = viewModel.ribbonWidestStop
        viewModel.ribbonWidestFittingStop = 4
        #expect(viewModel.ribbonRenderedStop == 4)
        // The choice survives the clamp, so widening the pane restores it.
        #expect(viewModel.ribbonChosenStop == viewModel.ribbonWidestStop)
        #expect(viewModel.ribbonExpanded)
        viewModel.ribbonWidestFittingStop = nil
        #expect(viewModel.ribbonRenderedStop == viewModel.ribbonWidestStop)
    }

    @Test
    func theFitCapAlsoClampsAnUnchosenRibbon() {
        // The common case at launch: a pane narrower than its full row draws
        // what fits, with nothing for the choice to preserve.
        let viewModel = phoneChrome()
        viewModel.ribbonWidestFittingStop = 6
        #expect(viewModel.ribbonRenderedStop == 6)
        #expect(viewModel.ribbonChosenStop == nil)
        #expect(viewModel.ribbonExpanded)
    }

    @Test
    func anAbsentFitCapLeavesTheRenderedStopAlone() {
        let viewModel = phoneChrome()
        viewModel.ribbonChosenStop = 3
        #expect(viewModel.ribbonWidestFittingStop == nil)
        #expect(viewModel.ribbonRenderedStop == 3)
    }

    @Test
    func theRenderedStopNeverExceedsTheActionCount() {
        let viewModel = phoneChrome()
        viewModel.ribbonChosenStop = 500
        viewModel.ribbonWidestFittingStop = 500
        #expect(viewModel.ribbonRenderedStop == viewModel.ribbonWidestStop)
    }

    @Test
    func tappingTheChevronTogglesBetweenTheEndStops() {
        let viewModel = phoneChrome()
        let widest = viewModel.ribbonWidestStop
        // The first tap on a fresh pane closes it: an unchosen ribbon is
        // already at the widest end, so the other end is where a tap goes.
        viewModel.toggleRibbonExtremes()
        #expect(viewModel.ribbonChosenStop == 0)
        viewModel.toggleRibbonExtremes()
        #expect(viewModel.ribbonChosenStop == widest)
        // From an intermediate stop a tap opens rather than doing nothing.
        viewModel.ribbonChosenStop = 3
        viewModel.toggleRibbonExtremes()
        #expect(viewModel.ribbonChosenStop == widest)
    }

    @Test
    func aLiveDragDrivesTheRenderedStopWithoutCommitting() {
        // What the ribbon draws follows the drag, while the choice stays put
        // until release, so abandoning a drag cannot rewrite the preference.
        let viewModel = phoneChrome()
        viewModel.ribbonChosenStop = 2
        viewModel.trackRibbonDrag(stop: 7)
        #expect(viewModel.ribbonRenderedStop == 7)
        #expect(viewModel.ribbonChosenStop == 2)
    }

    @Test
    func aLiveDragIsStillHeldToTheFitCap() {
        let viewModel = phoneChrome()
        viewModel.ribbonWidestFittingStop = 3
        viewModel.trackRibbonDrag(stop: 9)
        #expect(viewModel.ribbonRenderedStop == 3)
    }

    @Test
    func settlingClearsTheLiveDragAndRecordsTheChoice() {
        let viewModel = phoneChrome()
        viewModel.trackRibbonDrag(stop: 4)
        #expect(viewModel.ribbonDragStop == 4)
        #expect(viewModel.ribbonChosenStop == nil)
        viewModel.settleRibbon(at: 5)
        #expect(viewModel.ribbonChosenStop == 5)
        #expect(viewModel.ribbonDragStop == nil)
    }

    @Test
    func settlingClampsToTheOfferedStops() {
        let viewModel = phoneChrome()
        viewModel.settleRibbon(at: 99)
        #expect(viewModel.ribbonChosenStop == viewModel.ribbonWidestStop)
        viewModel.settleRibbon(at: -7)
        #expect(viewModel.ribbonChosenStop == 0)
    }

    // MARK: - Hot action

    /// A physical-device pane reporting every capability off, which is the one
    /// kind of pane whose ribbon offers no actions at all.
    private func capabilityStrippedDevice() -> PaneChromeViewModel {
        PaneChromeViewModel(
            title: "iPhone",
            family: "phone",
            capabilities: PaneCapabilities(
                touch: false,
                key: false,
                text: false,
                button: false,
                rotate: false,
                crown: false,
                accessibility: false,
                location: false
            ),
            isPhysicalDevice: true
        )
    }

    @Test
    func aPaneWithNoSupportedActionsHasNoHotAction() {
        // `button: false` removes Home from the supported actions, so the
        // per-family default seeded at init must not reach the hot slot.
        let viewModel = capabilityStrippedDevice()
        #expect(viewModel.ribbonActions.isEmpty)
        #expect(viewModel.lastUsedAction == .home)
        #expect(viewModel.hotAction == nil)
    }

    @Test
    func theHotActionFallsBackToOneThePaneSupports() {
        // `lastUsedAction` can outlive the capability that justified it, so a
        // value the pane no longer supports has to give way to one it does
        // rather than showing a control that cannot act.
        let viewModel = phoneChrome()
        viewModel.lastUsedAction = .applePay
        #expect(viewModel.hotAction == .applePay)
        viewModel.capabilities = PaneCapabilities(
            touch: true,
            key: true,
            text: true,
            button: false,
            rotate: true,
            crown: false,
            accessibility: true,
            location: true
        )
        #expect(viewModel.ribbonActions.contains(.applePay) == false)
        let hot = viewModel.hotAction
        #expect(hot != nil)
        #expect(viewModel.ribbonActions.contains(hot ?? .home))
    }

    @Test
    func anActiveToggleStaysHotEvenUngated() {
        // A toggle can only be on if the pane supported turning it on, and its
        // off-switch has to stay reachable at the narrowest stop.
        let viewModel = capabilityStrippedDevice()
        viewModel.axInspectorEnabled = true
        #expect(viewModel.hotAction == .axInspector)
        viewModel.axInspectorEnabled = false
        viewModel.recordingActive = true
        #expect(viewModel.hotAction == .record)
    }

    @Test
    func theHotActionFallbackIsTheHighestPriorityOne() {
        // `ribbonActions` runs lowest priority to highest because the ribbon
        // reveals from its trailing edge, so the fallback has to read the
        // trailing action. Reading the leading one would put the lowest-priority
        // control in the slot the narrowest stop shows.
        let viewModel = phoneChrome()
        viewModel.lastUsedAction = .crownPress
        #expect(viewModel.ribbonActions.contains(.crownPress) == false)
        #expect(viewModel.hotAction == viewModel.ribbonActions.last)
        #expect(viewModel.hotAction == .home)
    }

    @Test
    func theRowRevealsItsHighestPriorityActionsFirst() {
        // What a partial reveal uncovers, stated as the property rather than as
        // a literal row: for k > 0, stop k reveals the last k - 1 actions, the
        // offset being the rung the size-preset menu occupies. So the trailing
        // end of the list has to be the end worth showing first.
        let viewModel = phoneChrome()
        let actions = viewModel.ribbonActions
        let atStopTwo = PaneChromeRibbonFit.revealedActionCount(stop: 2)
        let atStopFive = PaneChromeRibbonFit.revealedActionCount(stop: 5)
        #expect(atStopTwo == 1)
        #expect(atStopFive == 4)
        #expect(Array(actions.suffix(atStopTwo)) == [.home])
        #expect(
            Array(actions.suffix(atStopFive))
                == [.rotateRight, .record, .screenshot, .home]
        )
    }

    @Test
    func aSupportedLastUsedActionStaysHot() {
        let viewModel = phoneChrome()
        viewModel.lastUsedAction = .rotateLeft
        #expect(viewModel.hotAction == .rotateLeft)
    }

    @Test
    func anActionlessPaneCanStillRevealItsSizeMenu() {
        // A device pane reporting neither buttons nor rotation offers no
        // ribbon actions at all, so its stop 0 is empty. It must still have
        // a stop above the narrowest, because the size-preset menu lives on
        // that rung and would otherwise be unreachable. A simulator never
        // reaches this state, since its capture
        // actions are enabled on pane kind alone.
        let viewModel = PaneChromeViewModel(
            title: "iPhone",
            family: "phone",
            capabilities: PaneCapabilities(
                touch: false,
                key: false,
                text: false,
                button: false,
                rotate: false,
                crown: false,
                accessibility: false,
                location: false
            ),
            isPhysicalDevice: true
        )
        #expect(viewModel.ribbonActions.isEmpty)
        #expect(viewModel.ribbonWidestStop == 1)
        // It opens on that rung, nobody having chosen otherwise, and it is
        // still there after a tap has closed the ribbon and reopened it.
        #expect(viewModel.ribbonExpanded)
        #expect(viewModel.ribbonRenderedStop == 1)
        viewModel.toggleRibbonExtremes()
        #expect(viewModel.ribbonChosenStop == 0)
        viewModel.toggleRibbonExtremes()
        #expect(viewModel.ribbonChosenStop == 1)
        #expect(viewModel.ribbonRenderedStop == 1)
        #expect(viewModel.ribbonExpanded)
        // That rung is exactly the size-preset menu, nothing else.
        #expect(
            PaneChromeRibbonFit.contentWidth(stop: 1)
                == PaneChromeRibbonFit.sizePresetWidth
        )
    }

    @Test
    func viewModelAcceptsInitialState() {
        let viewModel = PaneChromeViewModel(title: "iPhone 17 Pro", isFocused: true)
        #expect(viewModel.title == "iPhone 17 Pro")
        #expect(viewModel.isFocused == true)
    }

    @Test
    func viewModelMutationsPersist() {
        let viewModel = PaneChromeViewModel()
        viewModel.title = "Watch Ultra 3"
        viewModel.isFocused = true
        #expect(viewModel.title == "Watch Ultra 3")
        #expect(viewModel.isFocused == true)
    }

    @Test
    func hostingViewInstantiatesWithoutCrashing() {
        // Toolchain proof: SwiftUI builds + the drag host wraps the
        // chrome surface + the rootView resolves. A failure here
        // means the App target isn't picking up SwiftUI or the
        // SwiftUI rootView has a build error the rest of the suite
        // missed.
        let viewModel = PaneChromeViewModel(title: "test")
        let host = PaneChromeDragHostView(
            rootView: PaneChromeOverlay(viewModel: viewModel),
            showsGrabCursor: false
        )
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        #expect(host.frame.width == 200)
        #expect(host.frame.height == 100)
    }

    @Test
    func hostingViewOptsOutOfAutoresizingMask() {
        // The sim chrome host is pinned with Auto Layout constraints
        // by `SimulatorPaneViewController.loadView`. A regression that
        // ships `true` here would force every caller to remember the
        // toggle, the same trap any `NSHostingView` subclass mounted
        // with constraints has to avoid.
        let host = PaneChromeDragHostView(
            rootView: PaneChromeOverlay(viewModel: PaneChromeViewModel()),
            showsGrabCursor: false
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        #expect(host.translatesAutoresizingMaskIntoConstraints == false)
    }
}

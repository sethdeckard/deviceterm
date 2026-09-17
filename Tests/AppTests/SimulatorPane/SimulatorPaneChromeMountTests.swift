// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import Testing

/// The SwiftUI chrome's AppKit
/// integration gate. Six claims this pins:
///
///   1. The VC's chrome view model is seeded with the daemon-supplied
///      display name at init. The chrome is the first surface a user
///      sees the device name on; a regression here ships an unnamed
///      "iPhone Simulator" header.
///   2. After `loadView` runs, the chrome host AND the sim content
///      view are both mounted as siblings under the VC's wrapper view.
///      Collapsing the wrapper to a single content view, with chrome
///      overlaying the Metal surface, is the regression class this test
///      catches: chrome over the sim picture reads as "title painted
///      across the lock-screen wallpaper."
///   3. The chrome host is the pass-through subclass. A bare
///      `NSHostingView` mounted over interactive content would swallow
///      mouse events that should land on the sim or the shutdown
///      buttons. Pinning the concrete subclass means a future
///      "simplify by using NSHostingView directly" refactor breaks
///      here.
///   4. After layout, the chrome host occupies its own top strip and
///      the sim content view sits entirely below it. The non-overlap
///      check is the visual-layer assertion: chrome and sim never
///      share a pixel.
///   5. A pane opens with its ribbon as wide as the pane can draw, and no
///      device name narrows it. The name truncates behind the ribbon, so its
///      length cannot restrict which stops the ribbon can reach.
///   6. The fit cap tracks every layout pass while a chosen stop stays put.
///      That split is what lets a pane dragged narrow clamp what it draws
///      and restore the chosen stop when it widens again.
///
/// The stop assertions are relational, against
/// `PaneChromeRibbonFit.minimumPaneWidth(forStop:)`, rather than pinned
/// integers: the thresholds move with the row's constants, and the exact
/// arithmetic is already pinned in `PaneChromeRibbonFitTests`.
@MainActor
struct SimulatorPaneChromeMountTests {
    /// Widths for the fit-cap tests, against the ~400pt a 10-action phone
    /// row has to clear for its widest stop. `tooNarrow` is
    /// `simMinThickness`'s non-watch minimum width, so it is the narrowest a
    /// phone sim pane can be dragged to and still lands partway up the
    /// ladder rather than at the top.
    private let wideEnough: CGFloat = 900
    private let tooNarrow: CGFloat = 380
    /// A simulator name long enough to fill the chrome row on its own, used
    /// to check that title length does not move the ribbon's fit.
    private let longDisplayName = """
        iPhone 17e with a very long simulator name for testing pane titles \
        and truncation · iPhone 17e
        """

    private func makeViewController(
        displayName: String = "iPhone 17 Pro"
    ) -> SimulatorPaneViewController {
        let pane = SimPaneState(
            paneId: "p1",
            udid: "U-TEST",
            displayName: displayName,
            family: "phone"
        )
        let fake = FakeDaemonClient()
        return SimulatorPaneViewController(
            simPane: pane,
            daemonClient: fake,
            advisory: .silent(),
            deviceHubAdvisory: .silent()
        )
    }

    @Test
    func chromeViewModelSeedsTitleFromDisplayName() {
        let viewController = makeViewController(displayName: "iPhone 17 Pro")
        #expect(viewController.chromeViewModel.title == "iPhone 17 Pro")
        #expect(viewController.chromeViewModel.isFocused == false)
    }

    @Test
    func chromeAndContentMountAsSiblings() {
        let viewController = makeViewController()
        // `loadView` is private to NSViewController's bring-up; the
        // `view` accessor triggers it. Reading it once is the AppKit
        // pattern for forcing the view hierarchy to materialize in
        // a non-window-attached test context.
        _ = viewController.view
        let chromeHosts = viewController.view.subviews.compactMap {
            $0 as? PaneChromeDragHostView<PaneChromeOverlay>
        }
        let contents = viewController.view.subviews.compactMap {
            $0 as? SimulatorContentView
        }
        #expect(chromeHosts.count == 1)
        #expect(contents.count == 1)
    }

    @Test
    func chromeHostIsDragSourceWrapper() {
        // The sim chrome strip is wrapped in `PaneChromeDragHostView`
        // so pane-drag works from sim panes too: the user can grab
        // the strip and drop the pane onto a sibling to rearrange.
        // A refactor that drops the wrapper would silently disable
        // drag-from-sim and also lose the `slot = .sim(...)` payload
        // identity the destination decoder relies on.
        let viewController = makeViewController()
        _ = viewController.view
        let chrome = viewController.view.subviews.first {
            $0 is PaneChromeDragHostView<PaneChromeOverlay>
        } as? PaneChromeDragHostView<PaneChromeOverlay>
        #expect(chrome != nil)
        if case .sim(let udid) = chrome?.slot {
            #expect(udid == "U-TEST")
        } else {
            Issue.record("chrome host slot was not .sim — drag payload would carry the wrong identity")
        }
    }

    @Test
    func wrapperAcceptsFirstResponderForRearrangeSwap() {
        // PaneLayoutViewController's swap actions restore focus
        // post-swap via `window?.makeFirstResponder(focused.view)`,
        // where `focused.view` is this VC's root. A plain NSView
        // wrapper would default `acceptsFirstResponder` to false and
        // the keyboard focus would silently drop after every
        // ⌘⇧← / ⌘⇧→ / ⌃⇧D against a sim pane. The wrapper subclass
        // accepts first responder and forwards to the content view
        // so the responder chain lands where input is dispatched.
        let viewController = makeViewController()
        _ = viewController.view
        #expect(viewController.view.acceptsFirstResponder == true)
    }

    @Test
    func wrapperForwardsFirstResponderToContentView() {
        // Mount in a real window so `makeFirstResponder` actually
        // runs the responder-chain handoff. The wrapper accepts the
        // call but routes the responder status to the content view
        // (the input target); a regression that drops the forward
        // would leave the wrapper as firstResponder and input would
        // fall through to default NSView handling.
        let viewController = makeViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = viewController.view
        _ = window.makeFirstResponder(viewController.view)
        let content = viewController.view.subviews.first {
            $0 is SimulatorContentView
        }
        #expect(window.firstResponder === content)
    }

    @Test
    func becomingFirstResponderMarksChromeFocused() async throws {
        // The wrapper resolves focus from the responder chain and
        // mirrors it into chromeViewModel, where SwiftUI observes it
        // and re-renders the chrome's title brightening. The mirror is
        // one-way: the chrome never decides whether the pane is focused.
        let viewController = makeViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = viewController.view
        #expect(viewController.chromeViewModel.isFocused == false)
        _ = window.makeFirstResponder(viewController.view)
        window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(viewController.chromeViewModel.isFocused == true)
    }

    @Test
    func resigningFirstResponderClearsChromeFocus() async throws {
        let viewController = makeViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = viewController.view
        _ = window.makeFirstResponder(viewController.view)
        window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(viewController.chromeViewModel.isFocused == true)
        _ = window.makeFirstResponder(window)
        window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(viewController.chromeViewModel.isFocused == false)
    }

    @Test
    func wrapperBorderTracksFocusedState() async throws {
        // The focus ring around the entire pane lives on the wrapper's
        // CALayer (SwiftUI inside the chrome host would only ring the
        // chrome strip). Driven through the window, because the
        // responder chain is what the border answers to.
        let viewController = makeViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = viewController.view
        viewController.loadViewIfNeeded()
        let wrapper = try #require(
            viewController.view as? SimulatorPaneWrapperView,
            "VC root view is not the wrapper subclass"
        )
        #expect(wrapper.layer?.borderWidth ?? -1 == 0)
        _ = window.makeFirstResponder(viewController.view)
        window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect((wrapper.layer?.borderWidth ?? 0) > 0)
        _ = window.makeFirstResponder(window)
        window.update()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(wrapper.layer?.borderWidth ?? -1 == 0)
    }

    @Test
    func chromeAndContentDoNotOverlap() {
        // The whole point of the reserved-strip layout: the chrome
        // strip and the Metal sim picture never share a pixel. A
        // full-bounds chrome overlay renders the device name across
        // the guest's own screen; the chrome owns a top strip and
        // content fills the rest.
        let viewController = makeViewController()
        viewController.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        viewController.view.layoutSubtreeIfNeeded()
        guard
            let chrome = viewController.view.subviews.first(
                where: { $0 is PaneChromeDragHostView<PaneChromeOverlay> }
            ),
            let content = viewController.view.subviews.first(
                where: { $0 is SimulatorContentView }
            )
        else {
            Issue.record("chrome or content view missing after layout")
            return
        }
        #expect(chrome.frame.height > 0)
        #expect(content.frame.height > 0)
        #expect(chrome.frame.intersects(content.frame) == false)
        // Combined heights must cover the wrapper; no vertical gap.
        let combined = chrome.frame.height + content.frame.height
        #expect(combined == viewController.view.frame.height)
    }

    // MARK: - Opening width

    @Test
    func aWidePaneOpensTheRibbonFully() {
        let viewController = makeViewController()
        viewController.updateRibbonFitCap(paneWidth: wideEnough)
        let chrome = viewController.chromeViewModel
        #expect(chrome.ribbonRenderedStop == chrome.ribbonWidestStop)
        #expect(chrome.ribbonExpanded)
        // Nothing was chosen on the pane's behalf: the cap alone decided.
        #expect(chrome.ribbonChosenStop == nil)
    }

    @Test
    func aNarrowPaneOpensAsWideAsItFits() {
        // A pane too narrow for the whole row draws as much of it as the
        // row can hold, which is several rungs up rather than shut.
        let viewController = makeViewController()
        viewController.updateRibbonFitCap(paneWidth: tooNarrow)
        let chrome = viewController.chromeViewModel
        let stop = chrome.ribbonRenderedStop
        #expect(stop > 0)
        #expect(stop < chrome.ribbonWidestStop)
        // It is the widest that fits: one rung further would not.
        #expect(PaneChromeRibbonFit.minimumPaneWidth(forStop: stop) <= tooNarrow)
        #expect(PaneChromeRibbonFit.minimumPaneWidth(forStop: stop + 1) > tooNarrow)
    }

    @Test
    func aLongDeviceNameDoesNotNarrowTheRibbon() {
        // A long name and a short one must produce the same fit cap and the
        // same rendered stop at the same pane width: the name truncates
        // behind the ribbon and costs it nothing.
        let long = makeViewController(displayName: longDisplayName)
        let short = makeViewController()
        long.updateRibbonFitCap(paneWidth: wideEnough)
        short.updateRibbonFitCap(paneWidth: wideEnough)
        #expect(long.chromeViewModel.title == longDisplayName)
        #expect(
            long.chromeViewModel.ribbonWidestFittingStop
                == short.chromeViewModel.ribbonWidestFittingStop
        )
        #expect(
            long.chromeViewModel.ribbonRenderedStop
                == long.chromeViewModel.ribbonWidestStop
        )
        // And again at the phone pane's minimum width.
        long.updateRibbonFitCap(paneWidth: tooNarrow)
        short.updateRibbonFitCap(paneWidth: tooNarrow)
        #expect(
            long.chromeViewModel.ribbonRenderedStop
                == short.chromeViewModel.ribbonRenderedStop
        )
        #expect(long.chromeViewModel.ribbonRenderedStop > 0)
    }

    @Test
    func aVeryNarrowPaneFallsBackToTheHotActionAlone() {
        // Below even the narrowest rung's threshold the ribbon still has to
        // show one action, so the cap floors at stop 0 rather than refusing.
        let viewController = makeViewController()
        viewController.updateRibbonFitCap(paneWidth: 40)
        #expect(viewController.chromeViewModel.ribbonWidestFittingStop == 0)
        #expect(viewController.chromeViewModel.ribbonRenderedStop == 0)
    }

    @Test
    func theReservedChromeHeightIsTheSharedRowHeight() {
        // The strip the constraint reserves, the row SwiftUI draws, and the
        // resize handle's hit region are all this one number. The handle is
        // why it matters: the AppKit hit-test override withholds the handle's
        // whole column from the pane-drag host on x alone, so a gesture target
        // shorter than the reserved row would leave a band near the row's
        // edges that neither the resize nor the pane drag would take.
        #expect(
            SimulatorPaneViewController.chromeHeight(forFamily: "phone")
                == PaneChromeRibbonFit.chromeRowHeight
        )
        #expect(
            SimulatorPaneViewController.chromeHeight(forFamily: "watch")
                == PaneChromeRibbonFit.chromeRowHeight
        )
    }

    // MARK: - Narrowing fit cap

    @Test
    func theFitCapTracksLaterLayoutPassesWithoutReopeningTheChoice() {
        // The contract that makes narrowing survivable: the cap follows the
        // pane's current width while the chosen stop stays put, so dragging
        // a pane narrow clamps what it draws and widening it again restores
        // the choice rather than overwriting it.
        let viewController = makeViewController()
        let chrome = viewController.chromeViewModel
        chrome.settleRibbon(at: chrome.ribbonWidestStop)
        let chosen = chrome.ribbonWidestStop

        viewController.updateRibbonFitCap(paneWidth: tooNarrow)
        #expect(chrome.ribbonChosenStop == chosen)
        #expect(chrome.ribbonRenderedStop < chosen)
        #expect(chrome.ribbonExpanded)

        viewController.updateRibbonFitCap(paneWidth: wideEnough)
        #expect(chrome.ribbonRenderedStop == chosen)
    }

    @Test
    func aZeroWidthPassLeavesTheFitCapUnset() {
        // Panes lay out at zero bounds before the split seeds its ratios. A
        // pre-layout pass reports a width no user sees, and capping on it
        // would collapse the render to the hot-action stop for a frame.
        let viewController = makeViewController()
        viewController.updateRibbonFitCap(paneWidth: 0)
        #expect(viewController.chromeViewModel.ribbonWidestFittingStop == nil)
    }

    @Test
    func theFitCapDoesNotRecordAChoice() {
        // The cap governs the render only. A pane nobody has touched has to
        // stay unchosen however many layout passes it takes, so a later
        // widening opens it fully rather than restoring a stop the cap
        // happened to write.
        let viewController = makeViewController()
        viewController.updateRibbonFitCap(paneWidth: tooNarrow)
        #expect(viewController.chromeViewModel.ribbonChosenStop == nil)
        viewController.updateRibbonFitCap(paneWidth: wideEnough)
        #expect(viewController.chromeViewModel.ribbonChosenStop == nil)
        #expect(
            viewController.chromeViewModel.ribbonRenderedStop
                == viewController.chromeViewModel.ribbonWidestStop
        )
    }
}

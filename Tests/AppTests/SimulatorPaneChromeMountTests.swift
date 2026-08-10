// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimulatorPaneChromeMountTests: the SwiftUI chrome's AppKit
// integration gate. Five claims this pins:
//
//   1. The VC's chrome view model is seeded with the daemon-supplied
//      display name at init. The chrome is the first surface a user
//      sees the device name on; a regression here ships an unnamed
//      "iPhone Simulator" header.
//   2. After `loadView` runs, the chrome host AND the sim content
//      view are both mounted as siblings under the VC's wrapper view.
//      Collapsing the wrapper to a single content view, with chrome
//      overlaying the Metal surface, is the regression class this test
//      catches: chrome over the sim picture reads as "title painted
//      across the lock-screen wallpaper."
//   3. The chrome host is the pass-through subclass. A bare
//      `NSHostingView` mounted over interactive content would swallow
//      mouse events that should land on the sim or the shutdown
//      buttons. Pinning the concrete subclass means a future
//      "simplify by using NSHostingView directly" refactor breaks
//      here.
//   4. After layout, the chrome host occupies its own top strip and
//      the sim content view sits entirely below it. The non-overlap
//      check is the visual-layer assertion: chrome and sim never
//      share a pixel.
//   5. The launch-time ribbon fit: a pane wide enough for the
//      expanded ribbon plus its untruncated device name opens
//      expanded, a narrow one stays collapsed, provisional widths
//      during the launch resize decide nothing, and a single settled
//      pass freezes the answer in both directions.
//      `applyLaunchRibbonFit` takes a width so these drive the
//      sequence directly, without a window and its layout passes.

@testable import App
import AppKit
import DaemonProtocol
import Testing

@MainActor
struct SimulatorPaneChromeMountTests {
    /// Widths for the launch-fit tests, against the ~465pt threshold a
    /// 10-action phone row titled "iPhone 17 Pro" has to clear.
    /// `tooNarrow` is `simMinThickness`'s non-watch minimum width, so
    /// the narrowest a phone sim pane can be still stays collapsed.
    private let wideEnough: CGFloat = 900
    private let tooNarrow: CGFloat = 380

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
        return SimulatorPaneViewController(simPane: pane, daemonClient: fake)
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
    func becomingFirstResponderMarksChromeFocused() {
        // SimulatorContentView's becomeFirstResponder calls back into
        // the VC via SimulatorInputDelegate; the VC pushes the focus
        // bit into chromeViewModel where SwiftUI observes it and re-
        // renders the chrome's title brightening.
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
        #expect(viewController.chromeViewModel.isFocused == true)
    }

    @Test
    func resigningFirstResponderClearsChromeFocus() {
        let viewController = makeViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = viewController.view
        _ = window.makeFirstResponder(viewController.view)
        #expect(viewController.chromeViewModel.isFocused == true)
        _ = window.makeFirstResponder(nil)
        #expect(viewController.chromeViewModel.isFocused == false)
    }

    @Test
    func wrapperBorderTracksFocusedState() async throws {
        // The focus ring around the entire pane lives on the wrapper's
        // CALayer (SwiftUI inside the chrome host would only ring the
        // chrome strip). render() runs through observe() so a focus
        // mutation arrives on the next main-actor turn, so settle.
        let viewController = makeViewController()
        viewController.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        // Force viewDidLoad so the observe() binding arms.
        viewController.loadViewIfNeeded()
        guard let wrapper = viewController.view as? SimulatorPaneWrapperView else {
            Issue.record("VC root view is not the wrapper subclass")
            return
        }
        #expect(wrapper.layer?.borderWidth ?? -1 == 0)
        viewController.chromeViewModel.isFocused = true
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect((wrapper.layer?.borderWidth ?? 0) > 0)
        viewController.chromeViewModel.isFocused = false
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(wrapper.layer?.borderWidth ?? -1 == 0)
    }

    @Test
    func chromeAndContentDoNotOverlap() {
        // The whole point of the reserved-strip layout: the chrome
        // strip and the Metal sim picture never share a pixel. The
        // bug screenshot showed "iPhone 17 Pro" rendered across the
        // lock-screen wallpaper because the chrome was a full-
        // bounds overlay on the content view. After the fix the
        // chrome owns a top strip and content fills the rest.
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

    // MARK: - Launch-time ribbon fit

    @Test
    func wideLaunchOpensTheRibbonExpanded() {
        let viewController = makeViewController()
        #expect(viewController.chromeViewModel.ribbonExpanded == false)
        viewController.applyLaunchRibbonFit(paneWidth: wideEnough)
        #expect(viewController.chromeViewModel.ribbonExpanded)
    }

    @Test
    func narrowLaunchLeavesTheRibbonCollapsed() {
        // A narrow pane stays collapsed so the ribbon does not cover
        // the device name.
        let viewController = makeViewController()
        viewController.applyLaunchRibbonFit(paneWidth: tooNarrow)
        #expect(viewController.chromeViewModel.ribbonExpanded == false)
    }

    @Test
    func zeroWidthLayoutPassIsIgnored() {
        // Panes lay out at zero bounds before the split seeds its
        // ratios. Deciding there would latch "collapsed" on a width no
        // user ever sees, so the pass has to be skipped outright.
        let viewController = makeViewController()
        viewController.applyLaunchRibbonFit(paneWidth: 0)
        #expect(viewController.chromeViewModel.ribbonExpansionDecided == false)
        viewController.applyLaunchRibbonFit(paneWidth: wideEnough)
        #expect(viewController.chromeViewModel.ribbonExpanded)
    }

    @Test
    func pendingAutoFitSuppressesTheProvisionalWidth() {
        // The launch sequence resizes the pane: the split seeds
        // synthetic ratios, then the size-preset auto-fit resizes it
        // again. Passes taken while that fit is still pending report a
        // width the user never sees, so they must not decide anything.
        let viewController = makeViewController()
        viewController.pendingAutoFit = true
        viewController.applyLaunchRibbonFit(paneWidth: tooNarrow)
        #expect(viewController.chromeViewModel.ribbonExpansionDecided == false)
        #expect(viewController.chromeViewModel.ribbonExpanded == false)
        viewController.pendingAutoFit = false
        viewController.applyLaunchRibbonFit(paneWidth: wideEnough)
        #expect(viewController.chromeViewModel.ribbonExpanded)
    }

    @Test
    func aSingleSettledPassFreezesTheDecision() {
        // The launch answer must not depend on how many layout passes
        // AppKit happens to run: one pass with no auto-fit pending is
        // the whole decision. Anything looser lets a later window
        // resize or divider drag reopen it and toggle the ribbon under
        // the user.
        let viewController = makeViewController()
        viewController.applyLaunchRibbonFit(paneWidth: tooNarrow)
        #expect(viewController.chromeViewModel.ribbonExpansionDecided)
        viewController.applyLaunchRibbonFit(paneWidth: wideEnough)
        #expect(viewController.chromeViewModel.ribbonExpanded == false)
    }

    @Test
    func aWideLaunchAlsoFreezes() {
        // The mirror of the above: a pane that opened expanded stays
        // expanded when it's later dragged narrow. Frozen means
        // frozen in both directions.
        let viewController = makeViewController()
        viewController.applyLaunchRibbonFit(paneWidth: wideEnough)
        #expect(viewController.chromeViewModel.ribbonExpanded)
        viewController.applyLaunchRibbonFit(paneWidth: tooNarrow)
        #expect(viewController.chromeViewModel.ribbonExpanded)
    }

    @Test
    func aUserChoiceOutranksTheFit() {
        // What the chevron sets when the user clicks it. Their choice
        // holds even if the pane is plenty wide.
        let viewController = makeViewController()
        viewController.chromeViewModel.ribbonExpansionDecided = true
        viewController.applyLaunchRibbonFit(paneWidth: wideEnough)
        #expect(viewController.chromeViewModel.ribbonExpanded == false)
    }
}

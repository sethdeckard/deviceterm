// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// Pane focus navigation and the split fallback, driven through a real
/// `PaneLayoutViewController` in a real window.
///
/// The pure math is covered in `PaneFocusOrderMathTests` and
/// `PaneDirectionalFocusMathTests`. What these add is the wiring around
/// it: that the frame snapshot is taken in one coordinate space, that
/// focus actually moves, and that a split reports the focused pane as its
/// anchor. Those are the parts a pure test cannot see.
///
/// Stand-in pane VCs are plain `NSViewController`s. The controller
/// resolves focus by asking which pane view contains the first responder,
/// so it needs no libghostty surface or Metal view here.
///
/// Their root views forward first responder to a descendant, because both
/// real pane roots do: the view that has to end up focused is libghostty's
/// surface or the Metal content view, never the wrapper. A stub that
/// simply accepted focus itself would pass while the app left every
/// navigated-to pane unable to receive a keystroke.
@MainActor
struct PaneLayoutNavigationTests {
    /// Controller plus the window keeping it alive, since a released
    /// window takes the responder state with it.
    private struct Mounted {
        let controller: PaneLayoutViewController
        let window: NSWindow
    }

    private static let left = PaneSlot.terminal(TerminalPaneID(value: 1))
    private static let topRight = PaneSlot.terminal(TerminalPaneID(value: 2))
    private static let bottomRight = PaneSlot.terminal(TerminalPaneID(value: 3))

    // MARK: - Frame snapshot

    @Test
    func slotFramesCoversEveryPaneInOneCoordinateSpace() {
        let mount = makeMounted()
        let frames = mount.controller.slotFrames()
        #expect(Set(frames.keys) == [Self.left, Self.topRight, Self.bottomRight])
        guard let left = frames[Self.left],
            let topRight = frames[Self.topRight],
            let bottomRight = frames[Self.bottomRight] else {
            Issue.record("expected a frame for every pane")
            return
        }
        // The right column sits beyond the left pane, and its two panes
        // are stacked. Exact divider positions are AppKit's business;
        // the relations are what the direction walk reads.
        #expect(left.maxX <= topRight.minX)
        #expect(left.maxX <= bottomRight.minX)
        #expect(bottomRight.maxY <= topRight.minY)
        // One space, so the frames are directly comparable rather than
        // each being pane-local (which would put every origin at zero).
        #expect(left.minX < topRight.minX)
    }

    @Test
    func slotFramesSkipsAPaneNotInTheHierarchy() {
        // A VC in the registry whose view was pulled out mid-reconcile
        // has no meaningful frame, and reporting a stale one would aim
        // the arrows at a pane that is not on screen.
        let mount = makeMounted()
        mount.controller.paneVCs[Self.topRight]?.view.removeFromSuperview()
        #expect(mount.controller.slotFrames()[Self.topRight] == nil)
    }

    // MARK: - Focus resolution

    @Test
    func focusedSlotNamesThePaneContainingTheFirstResponder() {
        let mount = makeMounted()
        #expect(mount.controller.focusedSlot() == nil)
        focus(Self.bottomRight, in: mount)
        #expect(mount.controller.focusedSlot() == Self.bottomRight)
    }

    // MARK: - Next / Previous Pane

    @Test
    func focusLandsOnThePanesInputTargetNotItsRoot() {
        // The pane root is what the controller focuses, but the view that
        // has to end up first responder is the one below it. Land on the
        // root and the pane draws its ring and reports AXFocused while
        // every keystroke walks past it: focused to look at, dead to type
        // into.
        let mount = makeMounted()
        mount.controller.selectNextPane(nil)
        let paneVC = mount.controller.paneVCs[Self.left] as? StubPaneViewController
        #expect(mount.window.firstResponder === paneVC?.inputTarget)
    }

    @Test
    func nextPaneWalksDisplayOrderAndWraps() {
        let mount = makeMounted()
        focus(Self.left, in: mount)
        mount.controller.selectNextPane(nil)
        #expect(mount.controller.focusedSlot() == Self.topRight)
        mount.controller.selectNextPane(nil)
        #expect(mount.controller.focusedSlot() == Self.bottomRight)
        mount.controller.selectNextPane(nil)
        #expect(mount.controller.focusedSlot() == Self.left)
    }

    @Test
    func previousPaneWalksBackwardAndWraps() {
        let mount = makeMounted()
        focus(Self.left, in: mount)
        mount.controller.selectPreviousPane(nil)
        #expect(mount.controller.focusedSlot() == Self.bottomRight)
        mount.controller.selectPreviousPane(nil)
        #expect(mount.controller.focusedSlot() == Self.topRight)
    }

    @Test
    func nextPaneFromNoFocusEntersTheTab() {
        let mount = makeMounted()
        #expect(mount.controller.focusedSlot() == nil)
        mount.controller.selectNextPane(nil)
        #expect(mount.controller.focusedSlot() == Self.left)
    }

    // MARK: - Directional focus

    @Test
    func arrowsMoveByWhatIsOnScreen() {
        let mount = makeMounted()
        focus(Self.left, in: mount)
        mount.controller.selectPaneRight(nil)
        // Both right-column panes are candidates; either is a correct
        // answer for "right of the full-height left pane", and the math
        // tests pin which. Here the claim is that focus crossed.
        let landed = mount.controller.focusedSlot()
        #expect(landed == Self.topRight || landed == Self.bottomRight)

        focus(Self.bottomRight, in: mount)
        mount.controller.selectPaneAbove(nil)
        #expect(mount.controller.focusedSlot() == Self.topRight)
        mount.controller.selectPaneBelow(nil)
        #expect(mount.controller.focusedSlot() == Self.bottomRight)
        mount.controller.selectPaneLeft(nil)
        #expect(mount.controller.focusedSlot() == Self.left)
    }

    @Test
    func anArrowAtTheEdgeLeavesFocusWhereItIs() {
        let mount = makeMounted()
        focus(Self.left, in: mount)
        mount.controller.selectPaneLeft(nil)
        #expect(mount.controller.focusedSlot() == Self.left)
    }

    @Test
    func anArrowWithNoFocusedPaneDoesNothing() {
        // Unlike the cycling walk, a direction needs an origin. Guessing
        // one would drop the user into an arbitrary pane.
        let mount = makeMounted()
        mount.controller.selectPaneRight(nil)
        #expect(mount.controller.focusedSlot() == nil)
    }

    // MARK: - Split fallback

    @Test
    func splitRequestsCarryTheirAxis() {
        // Split Right puts panes side by side, which is a `.horizontal`
        // split. Getting this backwards is the easiest mistake here and
        // is invisible until a pane appears in the wrong place.
        let mount = makeMounted()
        var requests: [(anchor: PaneSlot?, axis: SplitAxis)] = []
        mount.controller.onSplitRequested = { requests.append(($0, $1)) }
        mount.controller.splitTerminalRight(nil)
        mount.controller.splitTerminalDown(nil)
        #expect(requests.map(\.axis) == [.horizontal, .vertical])
    }

    @Test
    func splitAnchorsOnTheFocusedPane() {
        let mount = makeMounted()
        var anchors: [PaneSlot?] = []
        mount.controller.onSplitRequested = { anchor, _ in anchors.append(anchor) }
        focus(Self.topRight, in: mount)
        mount.controller.splitTerminalRight(nil)
        #expect(anchors == [Self.topRight])
    }

    @Test
    func splitWithNoFocusedPaneAnchorsNowhere() {
        // Focus outside the tab emits a nil anchor rather than dropping
        // the request. Where a nil anchor puts the pane is
        // `addTerminal`'s business, and is covered there.
        let mount = makeMounted()
        var anchors: [PaneSlot?] = []
        var fired = 0
        mount.controller.onSplitRequested = { anchor, _ in
            anchors.append(anchor)
            fired += 1
        }
        mount.controller.splitTerminalDown(nil)
        #expect(fired == 1)
        #expect(anchors == [nil])
    }

    // MARK: - Accessibility identity

    @Test
    func everyPaneCarriesItsSlotIdentifier() {
        // The UI-test harness counts panes and names the focused one
        // from these, so a pane without one is invisible to it.
        let mount = makeMounted()
        for slot in [Self.left, Self.topRight, Self.bottomRight] {
            let identifier = mount.controller.paneVCs[slot]?.view.accessibilityIdentifier()
            #expect(identifier == PaneAccessibilityIdentity.identifier(for: slot))
        }
    }

    // MARK: - Harness

    /// `[left | [topRight / bottomRight]]`, mounted and laid out.
    private func makeMounted() -> Mounted {
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [
                .leaf(Self.left),
                .split(
                    axis: .vertical,
                    children: [.leaf(Self.topRight), .leaf(Self.bottomRight)],
                    extents: [1, 1]
                )
            ],
            extents: [1, 1]
        )
        let controller = PaneLayoutViewController(
            tabID: TabID(value: 1),
            router: nil,
            initialTree: tree,
            initialPaneVCs: [
                Self.left: StubPaneViewController(),
                Self.topRight: StubPaneViewController(),
                Self.bottomRight: StubPaneViewController()
            ]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = host
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return Mounted(controller: controller, window: window)
    }

    private func focus(_ slot: PaneSlot, in mount: Mounted) {
        guard let paneVC = mount.controller.paneVCs[slot] else {
            Issue.record("no pane VC for \(slot)")
            return
        }
        _ = mount.window.makeFirstResponder(paneVC.view)
    }
}

/// Stands in for a real pane VC: a root view that forwards focus to an
/// inner target, the shape both `TerminalPaneWrapperView` and
/// `SimulatorPaneWrapperView` have.
@MainActor
private final class StubPaneViewController: NSViewController {
    /// The view that should end up first responder, standing in for
    /// libghostty's surface.
    let inputTarget = FocusableView()

    override func loadView() {
        let root = ForwardingPaneView()
        root.inputTarget = inputTarget
        root.addSubview(inputTarget)
        view = root
    }
}

@MainActor
private final class ForwardingPaneView: NSView {
    weak var inputTarget: NSView?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard let inputTarget, let window else { return super.becomeFirstResponder() }
        return window.makeFirstResponder(inputTarget)
    }
}

@MainActor
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

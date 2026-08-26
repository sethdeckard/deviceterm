// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol

/// The per-tab container that materializes one
/// `PaneNode` tree into a recursive NSSplitView hierarchy. Supports
/// nested splits, drag-to-rearrange, and tree-driven auto-rebalance.
///
/// The controller owns a root container view. A reconcile updates
/// controller membership and rebuilds the NSSplitView hierarchy in place
/// only when the tree has changed, reusing existing pane VC views. Pane VCs are child
/// controllers of this controller so their lifecycle methods fire at
/// the right times regardless of how deeply nested their view sits.
///
/// Drag destination: registers for the custom pane-drag pasteboard
/// type, computes the cursor's drop zone over the hovered leaf, and
/// renders a translucent overlay in the future-position. On drop,
/// dispatches `Route.reorderPane` so the nav state mutates and the
/// reconcile picks up the new tree.
///
/// All the @objc forwarders for Window-menu size presets, Device-menu
/// hardware buttons, and AX inspector toggle live here. They
/// dispatch to the focused / first sim pane through the
/// responder chain.
@MainActor
final class PaneLayoutViewController: NSViewController, NSUserInterfaceValidations {
    /// Resolved parent-split lookup for size-preset application.
    struct ParentSplit {
        let splitView: NSSplitView
        let indexInParent: Int
        let axis: SplitAxis
    }

    /// Tab id the controller is bound to, used for drag-payload tab
    /// match-check and for dispatching `Route.reorderPane`.
    let tabID: TabID
    /// Router injected so the drag destination can dispatch reorder
    /// intents without reaching for a singleton.
    /// `internal` (not `private`): read by the `+DragDestination` file.
    weak var router: Router?
    /// Split-request sink for the Split Right / Split Down fallback in
    /// the `+Split` file. The owning `TabContentViewController` wires it,
    /// because the new terminal inherits the tab's working directory and
    /// that value lives there. A split anchored on a device pane has no
    /// pane-local cwd to inherit. `anchor` is the pane to split beside,
    /// nil when nothing in this tab holds focus.
    var onSplitRequested: ((_ anchor: PaneSlot?, _ axis: SplitAxis) -> Void)?

    // Pane VC registry, keyed by slot. Reconcile populates it from
    // the factory closures the caller passes per-slot.
    // `paneVCs` + `tree` are `internal` (not `private`): the drag
    // hit-test in the `+DragDestination` file reads both live.
    var paneVCs: [PaneSlot: NSViewController] = [:]
    var tree: PaneNode
    /// The split-view ratio state (per-split proportions, the
    /// split↔path registry, and the programmatic-apply re-entrancy
    /// guard). The controller keeps the AppKit view-tree walking below
    /// and routes every state read/write through this store.
    private let ratioStore = PaneRatioStore()
    /// Path of each sim slot the last time `reconcile` ran. A sim's
    /// path changes when it's first added, when the user drags it
    /// into a new sub-split, or when an ancestor split compacts.
    /// Diffed on every `reconcile` to drive `pendingAutoFit`.
    private var lastSimPaths: [PaneSlot: [Int]] = [:]
    /// Sim slots whose Point Accurate auto-fit should run on the
    /// next layout pass (once the new split's bounds are real and
    /// the sim VC's pixel dimensions have arrived from the IOSurface).
    /// The set drains each time `flushPendingAutoFits` succeeds.
    private var pendingAutoFit: Set<PaneSlot> = []
    /// True from the end of a `reconcile` until the first `viewDidLayout`
    /// that applies the freshly-seeded ratios against real (non-zero)
    /// bounds. While set, `splitViewDidResizeSubviews` skips its
    /// delegate-driven `captureRatios` so AppKit's default distribution
    /// on the first layout of a rebuilt split (which hands a reused
    /// sibling its old extent and a brand-new sibling only its minimum)
    /// can't overwrite the correct seed before `applyRatios` applies it.
    /// The `withApply` guard around the reconcile trio only covers the
    /// *synchronous* rebuild window; this covers the *asynchronous*
    /// first-layout window that follows. Direct `applySizePreset`
    /// captures are unaffected, so sim pixel-exact width still persists.
    private var awaitingFirstApply = false

    /// Drag-overlay layer; nil when no drag is in flight.
    /// `internal` (not `private`): owned by the `+DragDestination` file.
    var dropOverlayLayer: CALayer?
    /// Cached drag overlay color resolved from `GhosttyThemeColors`.
    /// Computed once per drag session (re-read on `draggingEntered`
    /// so a config change between drags picks up).
    /// `internal` (not `private`): owned by the `+DragDestination` file.
    var dropOverlayColor: NSColor = .controlAccentColor

    /// All terminal pane VCs in display order, for the
    /// validate / dispatch callers that walk `terminalVCs`.
    var terminalVCs: [TerminalPaneViewController] {
        PaneTreeOps.leavesInOrder(tree).compactMap {
            paneVCs[$0] as? TerminalPaneViewController
        }
    }

    /// All sim pane VCs in display order.
    var simPanes: [SimulatorPaneViewController] {
        PaneTreeOps.leavesInOrder(tree).compactMap {
            paneVCs[$0] as? SimulatorPaneViewController
        }
    }

    init(
        tabID: TabID,
        router: Router?,
        initialTree: PaneNode,
        initialPaneVCs: [PaneSlot: NSViewController]
    ) {
        self.tabID = tabID
        self.router = router
        self.tree = initialTree
        self.paneVCs = initialPaneVCs
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    // MARK: - Min thickness constants (per axis, per family)

    /// Per-axis minimum thickness for a terminal split item.
    /// `isVertical` describes the parent split's divider: a vertical
    /// divider → items arranged side-by-side, thickness is width.
    static func terminalMinThickness(isVertical: Bool) -> CGFloat {
        isVertical ? 320 : 120
    }

    /// Per-axis minimum thickness for a sim split item, family-aware.
    static func simMinThickness(family: DeviceFamily, isVertical: Bool) -> CGFloat {
        if isVertical {
            return family == .watch ? 220 : 380
        }
        return family == .watch ? 200 : 280
    }

    /// Shared sim/device/pending natural+minimum extent for a family
    /// along the given divider axis (non-flexible, since these aspect-fit, so
    /// they don't absorb leftover space the way terminals do). A pending
    /// placeholder sizes identically to the sim/device pane it becomes.
    static func mirroredMetric(
        slot: PaneSlot,
        family: DeviceFamily,
        isVerticalDivider: Bool
    ) -> PaneSlotMetrics {
        PaneSlotMetrics(
            slot: slot,
            naturalExtent: isVerticalDivider
                ? (family == .watch ? 220 : 380)
                : (family == .watch ? 200 : 280),
            minimumExtent: simMinThickness(family: family, isVertical: isVerticalDivider),
            isFlexible: false
        )
    }

    override func loadView() {
        view = PaneLayoutContainerView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for paneVC in paneVCs.values {
            addChild(paneVC)
        }
        rebuildHierarchy()
        applyAccessibilityIdentifiers()
        view.registerForDraggedTypes([NSPasteboard.PasteboardType(PaneDragPayload.pasteboardType)])
        // The container view forwards drag callbacks back to us.
        (view as? PaneLayoutContainerView)?.dragDelegate = self
        // Initial focus-border gate. A fresh tab starts at one pane,
        // so the single pane suppresses the ring; the first
        // `reconcile` (after addTerminal / drag drop / etc.) flips it
        // on when the leaf count crosses one.
        updateFocusBorderGates()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyRatios()
        // Once a real layout has applied the seed against non-zero
        // bounds, lift the post-reconcile capture suppression so user
        // divider drags stick again. Require BOTH dimensions positive:
        // `applyRatios` sizes side-by-side splits along width and stacked
        // splits along height, so an intermediate pass with height > 0
        // but width == 0 (or vice versa) hasn't applied a horizontal
        // split's ratios yet, and clearing there would let the next layout
        // capture AppKit's default distribution, the very regression this
        // guard prevents. Cleared before `flushPendingAutoFits`, since a fresh
        // sim's `applySizePreset` captures directly, so its pixel-exact
        // width persists either way.
        if awaitingFirstApply, let rootBounds = view.subviews.first?.bounds,
            rootBounds.width > 0, rootBounds.height > 0 {
            awaitingFirstApply = false
        }
        // Drain any sim VC waiting for a Point Accurate auto-fit
        // AFTER applyRatios completes (depth back to 0) so its
        // `splitViewDidResizeSubviews` callback captures the new
        // ratios. Running this inside reconcile failed: rebuildHierarchy
        // creates a fresh NSSplitView whose bounds are zero, the
        // preset math collapsed siblings to their minimum thickness
        // (one of the original sims would disappear), and only a
        // user drag would re-balance. viewDidLayout fires after
        // AppKit has populated bounds, so sizing math works.
        flushPendingAutoFits()
    }

    /// For each sim VC still waiting on Point Accurate auto-fit, try
    /// to land it. The VC's own gating (window mounted, pixel dims
    /// known) decides whether the call actually applies the preset
    /// or short-circuits; a fresh-attach sim short-circuits on first
    /// pass and lights up later via `render()` once the IOSurface
    /// publishes dims, while a drag-rearrange sim applies on the
    /// first pass after the reconcile.
    private func flushPendingAutoFits() {
        for paneVC in paneVCs.values {
            if let simVC = paneVC as? SimulatorPaneViewController, simVC.pendingAutoFit {
                simVC.tryAutoFitNow()
            }
        }
    }

    /// Mark each pending sim VC's own `pendingAutoFit` flag. The VC's
    /// `render()` picks it up once the IOSurface delivers pixel
    /// dimensions (fresh-attach path), and `viewDidLayout` →
    /// `flushPendingAutoFits` picks it up once split bounds settle
    /// (drag-rearrange path). The flag clears VC-side once the
    /// preset actually applies; subsequent reconciles re-arm via
    /// the `lastSimPaths` diff in `reconcile`. We deliberately do
    /// NOT call `tryAutoFitNow()` here: bounds are zero straight
    /// out of `rebuildHierarchy` and the preset math would collapse
    /// a sibling pane to its minimum thickness.
    private func armPendingAutoFits() {
        let slots = pendingAutoFit
        pendingAutoFit.removeAll()
        for slot in slots {
            if let simVC = paneVCs[slot] as? SimulatorPaneViewController {
                simVC.pendingAutoFit = true
            }
        }
    }

    /// Look up the terminal pane VC for a specific id. The owning
    /// `TabContentViewController` uses this to route tab-scoped
    /// operations (`sendInput`, `captureScreen`, tab-switch focus)
    /// at the **original** primary terminal (`TabState.primaryTerminal
    /// .id`) instead of whatever leaf happens to be first in tree
    /// order after a drag rearrange. "Primary" is a nav-state concept;
    /// the layout controller doesn't define it.
    func terminalVC(for id: TerminalPaneID) -> TerminalPaneViewController? {
        paneVCs[.terminal(id)] as? TerminalPaneViewController
    }

    // MARK: - Reconcile API

    /// Replace the tree with `newTree`. `paneVCFactory` is invoked once
    /// for any slot present in the new tree but absent from the
    /// current pane VC registry; removed slots have their VCs dropped
    /// (caller has already torn down the daemon-side resources).
    ///
    /// Three early-returns matter:
    ///   1. Identical tree + identical pane VC membership → no-op.
    ///      The observation pipeline fires this on every nav-state
    ///      change in the tab (sim lifecycle, title, etc.), and
    ///      re-parenting the libghostty surface during a no-op tree
    ///      pass disturbs attach timing.
    ///   2. Same tree, different membership → just update the VC
    ///      registry; no view hierarchy rebuild.
    ///   3. Different tree → full rebuild, preserving keyboard focus
    ///      on the previously-focused slot so the user can keep
    ///      typing after a drag rearrange or ⌘⇧← / ⌘⇧→. When that slot
    ///      is one of the panes going away, focus hands off to the
    ///      nearest surviving neighbor instead.
    func reconcile(
        tree newTree: PaneNode,
        paneVCFactory: (PaneSlot) -> NSViewController?
    ) {
        let newSlots = Set(PaneTreeOps.leavesInOrder(newTree))
        let oldSlots = Set(paneVCs.keys)
        // Resolve where focus belongs BEFORE any teardown. Removing a
        // pane's view drops the window's first responder, so asking
        // afterwards names nothing and the tab is left with no focused
        // pane. Every pane removal that leaves the tab open arrives
        // here, whichever affordance started it, which is why the
        // handoff lives in this path rather than in any one of them.
        let focusTarget = PaneFocusOrderMath.survivor(
            of: focusedSlot(),
            order: PaneTreeOps.leavesInOrder(tree),
            surviving: newSlots
        )
        for slot in oldSlots.subtracting(newSlots) {
            if let paneVC = paneVCs.removeValue(forKey: slot) {
                paneVC.removeFromParent()
                paneVC.view.removeFromSuperview()
            }
        }
        for slot in newSlots.subtracting(oldSlots) {
            guard let paneVC = paneVCFactory(slot) else { continue }
            paneVCs[slot] = paneVC
            addChild(paneVC)
        }
        // Before the tree-equality early return: membership can change
        // with the tree untouched (a pending leaf swapping to the real
        // pane keeps its position), and that swap changes identity.
        applyAccessibilityIdentifiers()
        guard newTree != tree else { return }
        // Sim path diff drives the auto-fit. A sim is marked only
        // when it's NEW or its **parent split** changed. A sibling
        // shuffle (e.g. an existing sim's index moves [1]→[2] because
        // a new sim was inserted before it) leaves the parent path
        // unchanged and does NOT re-fit. Without this guard, every
        // new-sim attach would also re-fit every previously-existing
        // sim under the same root split: the cascading divider
        // moves would collapse one of the originals to its minimum
        // thickness (invisible pane) until the user dragged
        // something to force a re-balance.
        let nextSimPaths = simSlotPaths(in: newTree)
        for (slot, path) in nextSimPaths {
            let oldPath = lastSimPaths[slot]
            let newParent = Array(path.dropLast())
            let oldParent = oldPath.map { Array($0.dropLast()) }
            if oldPath == nil || newParent != oldParent {
                pendingAutoFit.insert(slot)
            }
        }
        lastSimPaths = nextSimPaths
        tree = newTree
        // Raise the apply guard across the whole seed→rebuild→apply
        // sequence. `rebuildHierarchy` builds fresh NSSplitViews whose
        // transient zero-bounds layout fires `splitViewDidResizeSubviews`
        // synchronously; without the guard those callbacks would
        // `captureRatios` over the ratios `recomputeRatios` just seeded,
        // storing a [1, ~0]-shaped garbage proportion that `applyRatios`
        // then applies, collapsing a freshly-split sibling to its
        // minimum thickness. (Sim panes masked this via the
        // `pendingAutoFit` → `viewDidLayout` re-fit; a terminal split has
        // no such recovery, so the collapse stuck.)
        ratioStore.withApply {
            recomputeRatios()
            rebuildHierarchy()
            applyRatios()
        }
        // The `applyRatios` above ran against zero-bounds fresh splits, so
        // the seed is stored but not yet visibly applied. Suppress delegate
        // captures until the first real layout applies it (see
        // `awaitingFirstApply`), or AppKit's default first-layout
        // distribution would clobber the seed.
        awaitingFirstApply = true
        updateFocusBorderGates()
        armPendingAutoFits()
        restoreFocus(to: focusTarget)
    }

    /// Stamp each pane's root view with its slot identifier, so the
    /// out-of-process UI-test harness can count panes and name the
    /// focused one from an accessibility dump. Cheap and idempotent, so
    /// it runs on every membership change rather than being diffed.
    private func applyAccessibilityIdentifiers() {
        for (slot, paneVC) in paneVCs {
            paneVC.view.setAccessibilityIdentifier(
                PaneAccessibilityIdentity.identifier(for: slot)
            )
        }
    }

    /// Walk `tree` and return `slot → path` for every sim leaf.
    /// Used by the reconcile diff to decide which sim panes need
    /// auto-fit on the next layout pass.
    private func simSlotPaths(in tree: PaneNode) -> [PaneSlot: [Int]] {
        var result: [PaneSlot: [Int]] = [:]
        walkLeaves(node: tree, path: []) { slot, path in
            if case .sim = slot {
                result[slot] = path
            }
        }
        return result
    }

    private func walkLeaves(
        node: PaneNode,
        path: [Int],
        body: (PaneSlot, [Int]) -> Void
    ) {
        switch node {
        case let .leaf(slot):
            body(slot, path)

        case let .split(_, children, _):
            for (index, child) in children.enumerated() {
                walkLeaves(node: child, path: path + [index], body: body)
            }
        }
    }

    /// Flip `focusBorderEnabled` on each pane VC's wrapper view based
    /// on whether the tab holds more than one pane. A solo pane has
    /// no rearrange affordances (no neighbor to swap with, no
    /// divider to drag), so a focus ring would be visual noise; the
    /// gate suppresses it. Multi-pane tabs re-enable it so the
    /// focused pane stays visually distinct.
    private func updateFocusBorderGates() {
        let leaves = PaneTreeOps.leavesInOrder(tree)
        let enabled = leaves.count > 1
        for (_, paneVC) in paneVCs {
            if let wrapper = paneVC.view as? SimulatorPaneWrapperView {
                wrapper.focusBorderEnabled = enabled
            } else if let wrapper = paneVC.view as? TerminalPaneWrapperView {
                wrapper.focusBorderEnabled = enabled
            }
        }
    }

    /// Force a fresh auto-rebalance pass without touching pane VC
    /// membership. Wired to the View > Reset Pane Layout menu item.
    /// Routes each split's children through `PaneAutoLayout.extents`
    /// against the split's current bounds so the flexible-terminal /
    /// natural-sim trade-off the helper documents actually drives
    /// the resulting divider positions.
    func resetLayout() {
        let focusedBefore = focusedSlot()
        ratioStore.clearRatios()
        recomputeRatiosFromAutoLayout()
        applyRatios()
        restoreFocus(to: focusedBefore)
    }

    /// `internal` (not `private`): the pane-navigation forwarders in the
    /// `+PaneNavigation` file move focus through this.
    func restoreFocus(to slot: PaneSlot?) {
        guard let slot,
            let paneVC = paneVCs[slot] else { return }
        paneVC.view.window?.makeFirstResponder(paneVC.view)
    }

    // MARK: - Hierarchy build

    private func rebuildHierarchy() {
        view.subviews.forEach { $0.removeFromSuperview() }
        ratioStore.clearSplits()
        let root = makeView(for: tree, path: [])
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func makeView(for node: PaneNode, path: [Int]) -> NSView {
        switch node {
        case let .leaf(slot):
            let paneView = paneVCs[slot]?.view ?? NSView()
            paneView.removeFromSuperview()
            return paneView

        case let .split(axis, children, _):
            let split = NSSplitView()
            split.isVertical = (axis == .horizontal)
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = false
            split.delegate = self
            ratioStore.register(split, path: path)
            for (index, child) in children.enumerated() {
                let childView = makeView(for: child, path: path + [index])
                childView.translatesAutoresizingMaskIntoConstraints = false
                split.addArrangedSubview(childView)
            }
            return split
        }
    }

    // MARK: - Ratios + auto-rebalance

    /// Seed the ratio store from the natural extents of every split
    /// for which we don't yet have a stored ratio. Pure proportional,
    /// with no flexible / aspect-fit redistribution. Called on every tree
    /// mutation so a fresh-from-insert split has sensible-looking
    /// dividers; `resetLayout` uses `recomputeRatiosFromAutoLayout`
    /// instead to apply the documented flexible-absorbs-slack rule.
    private func recomputeRatios(fromScratch: Bool = false) {
        if fromScratch {
            ratioStore.clearRatios()
        }
        walkSplits(node: tree, path: []) { node, path in
            guard case let .split(axis, children, _) = node else { return }
            if !fromScratch, ratioStore.ratios(forPath: path)?.count == children.count { return }
            let metrics = children.map { metric(for: $0, alongAxis: axis) }
            ratioStore.setRatios(
                PaneRatioMath.proportions(naturalExtents: metrics.map(\.naturalExtent)),
                forPath: path
            )
        }
    }

    /// Reset-Pane-Layout path: run `PaneAutoLayout.extents` per split
    /// against each split's actual bounds so the flexible-terminal /
    /// natural-sim trade-off applies. Cached as ratios so subsequent
    /// resizes scale proportionally instead of re-running the
    /// flexible math on every layout (which would override user
    /// divider drags on the next resize).
    private func recomputeRatiosFromAutoLayout() {
        walkSplits(node: tree, path: []) { node, path in
            guard case let .split(axis, children, _) = node else { return }
            let metrics = children.map { metric(for: $0, alongAxis: axis) }
            let split = splitView(for: path)
            let axisExtent: CGFloat = (split?.isVertical ?? true)
                ? (split?.bounds.width ?? 0)
                : (split?.bounds.height ?? 0)
            let dividerThickness = split?.dividerThickness ?? 1
            let usable = PaneRatioMath.usableExtent(
                axisExtent: axisExtent,
                dividerThickness: dividerThickness,
                count: children.count
            )
            // No bounds yet (initial layout): leave the previous
            // ratios in place; the next viewDidLayout will pick up
            // a sensible scaling.
            guard usable > 0 else { return }
            let extents = PaneAutoLayout.extents(
                children: metrics,
                availableExtent: usable
            )
            guard let normalized = PaneRatioMath.normalize(extents) else { return }
            ratioStore.setRatios(normalized, forPath: path)
        }
    }

    private func splitView(for path: [Int]) -> NSSplitView? {
        guard let oid = ratioStore.splitIdentifier(forPath: path) else { return nil }
        return splitView(forID: oid)
    }

    private func splitView(forID oid: ObjectIdentifier) -> NSSplitView? {
        // Walk the current hierarchy. The map is small (one entry per
        // split node) so a linear search is fine.
        var candidates: [NSView] = view.subviews
        while let next = candidates.popLast() {
            if let split = next as? NSSplitView, ObjectIdentifier(split) == oid {
                return split
            }
            candidates.append(contentsOf: next.subviews)
        }
        return nil
    }

    private func applyRatios() {
        ratioStore.withApply {
            applyRatios(node: tree, path: [], view: view.subviews.first)
        }
    }

    private func applyRatios(node: PaneNode, path: [Int], view rawView: NSView?) {
        guard case let .split(_, children, _) = node,
            let split = rawView as? NSSplitView else { return }
        guard children.count >= 2 else { return }
        let stored = ratioStore.ratios(forPath: path)
        let ratios: [CGFloat]
        if let stored, stored.count == children.count {
            ratios = stored
        } else {
            // Either nothing cached or a stale entry of the wrong
            // count (e.g. captureRatios fired during an in-flight
            // rebuild). Fall back to even split rather than indexing
            // out of bounds.
            ratios = PaneRatioMath.evenSplit(count: children.count)
        }
        let axisExtent: CGFloat = split.isVertical ? split.bounds.width : split.bounds.height
        let dividerThickness = split.dividerThickness
        let usable = PaneRatioMath.usableExtent(
            axisExtent: axisExtent,
            dividerThickness: dividerThickness,
            count: children.count
        )
        let positions = PaneRatioMath.dividerPositions(
            ratios: ratios,
            usableExtent: usable,
            dividerThickness: dividerThickness
        )
        for (index, position) in positions.enumerated() {
            split.setPosition(position, ofDividerAt: index)
        }
        for (index, childNode) in children.enumerated() {
            let childView = split.arrangedSubviews[safe: index]
            applyRatios(node: childNode, path: path + [index], view: childView)
        }
    }

    private func walkSplits(
        node: PaneNode,
        path: [Int],
        body: (PaneNode, [Int]) -> Void
    ) {
        if case let .split(_, children, _) = node {
            body(node, path)
            for (index, child) in children.enumerated() {
                walkSplits(node: child, path: path + [index], body: body)
            }
        }
    }

    /// Snapshot the current divider positions of `split` back into
    /// the ratio store so subsequent `applyRatios` passes preserve the
    /// freshly-set proportions instead of overwriting them with stale
    /// ratios. Called after `applySizePreset` moves a divider, and on
    /// `splitViewDidResizeSubviews` so user divider drags also stick.
    private func captureRatios(for split: NSSplitView) {
        guard let path = ratioStore.path(for: split) else { return }
        let extents: [CGFloat] = split.arrangedSubviews.map {
            split.isVertical ? $0.frame.width : $0.frame.height
        }
        guard let normalized = PaneRatioMath.normalize(extents) else { return }
        ratioStore.setRatios(normalized, forPath: path)
    }

    // MARK: - PaneSlotMetrics

    /// Compute a node's metric along `parentAxis` (the axis the
    /// enclosing split arranges its children along). For a leaf this
    /// is the pane's per-axis natural / minimum extent. For a nested
    /// split:
    ///   - same axis as parent → children share the constrained axis,
    ///     so the SUM of child extents is the right answer;
    ///   - perpendicular axis → children stack the OTHER way, and the
    ///     parent-axis dimension is whatever the widest child needs,
    ///     so we take the MAX. Summing here would over-allocate a
    ///     stacked subtree and crush its neighbors.
    private func metric(for node: PaneNode, alongAxis parentAxis: SplitAxis) -> PaneSlotMetrics {
        switch node {
        case let .leaf(slot):
            return leafMetric(for: slot, alongAxis: parentAxis)

        case let .split(nestedAxis, children, _):
            let childMetrics = children.map { metric(for: $0, alongAxis: parentAxis) }
            let natural: CGFloat
            let minimum: CGFloat
            if nestedAxis == parentAxis {
                natural = childMetrics.reduce(0) { $0 + $1.naturalExtent }
                minimum = childMetrics.reduce(0) { $0 + $1.minimumExtent }
            } else {
                natural = childMetrics.map(\.naturalExtent).max() ?? 1
                minimum = childMetrics.map(\.minimumExtent).max() ?? 0
            }
            // The slot field carries no meaning for a split node;
            // PaneSlotMetrics is just a value carrier and the
            // placement math only consumes the extents + flex bit.
            return PaneSlotMetrics(
                slot: .terminal(TerminalPaneID(value: -1)),
                naturalExtent: max(natural, 1),
                minimumExtent: minimum,
                isFlexible: childMetrics.contains(where: \.isFlexible)
            )
        }
    }

    /// `parentAxis == .horizontal` means side-by-side siblings, so we're
    /// measuring widths and `isVerticalDivider == true`.
    /// `parentAxis == .vertical` means stacked siblings, so we're
    /// measuring heights and `isVerticalDivider == false`.
    private func leafMetric(for slot: PaneSlot, alongAxis parentAxis: SplitAxis) -> PaneSlotMetrics {
        let isVerticalDivider = (parentAxis == .horizontal)
        switch slot {
        case .terminal:
            return PaneSlotMetrics(
                slot: slot,
                naturalExtent: isVerticalDivider ? 480 : 200,
                minimumExtent: Self.terminalMinThickness(isVertical: isVerticalDivider),
                isFlexible: true
            )

        // Sim and physical-device panes both render through
        // `SimulatorPaneViewController`, so they size identically (a device
        // reports family `.unknown` → phone-default metrics).
        case .sim, .device:
            let family = (paneVCs[slot] as? SimulatorPaneViewController)
                .map { DeviceFamily(wire: $0.family) } ?? .unknown
            return Self.mirroredMetric(
                slot: slot,
                family: family,
                isVerticalDivider: isVerticalDivider
            )

        // A pending placeholder sizes exactly like the sim/device pane it
        // will become, so the success swap doesn't resize the split. Its
        // family rides on the `PendingPaneViewController` (`.unknown` →
        // phone-default); the real pane's pixels then drive the auto-fit.
        case .pending:
            let family = (paneVCs[slot] as? PendingPaneViewController)
                .map { DeviceFamily(wire: $0.family) } ?? .unknown
            return Self.mirroredMetric(
                slot: slot,
                family: family,
                isVerticalDivider: isVerticalDivider
            )
        }
    }

    // MARK: - Responder-chain swap / toggle / size preset (forwarded)

    @objc
    func swapPaneLeft(_ sender: Any?) { swapFocusedPane(direction: -1) }

    @objc
    func swapPaneRight(_ sender: Any?) { swapFocusedPane(direction: +1) }

    private func swapFocusedPane(direction: Int) {
        guard let focused = focusedSlot() else { return }
        let order = PaneTreeOps.leavesInOrder(tree)
        guard let here = order.firstIndex(of: focused) else { return }
        let target = here + direction
        guard target >= 0, target < order.count else { return }
        router?.dispatch(.reorderPane(
            tab: tabID,
            slot: focused,
            target: order[target],
            zone: .center
        ))
    }

    @objc
    func toggleSplitDirection(_ sender: Any?) {
        // Flip the split that directly contains the focused pane.
        // Only that split re-orients; panes elsewhere stay put. A
        // single-pane tab has no split to flip; the Route is a no-op
        // there, so there's nothing to special-case.
        guard let focused = focusedSlot() else { return }
        router?.dispatch(.flipSplitAxis(tab: tabID, slot: focused))
    }

    /// Resize `pane` to `preset`'s extent along the relevant axis by
    /// finding its parent split and setting the divider at the pane's
    /// trailing edge.
    func applySizePreset(
        _ preset: SimSizePreset,
        forSimPane pane: SimulatorPaneViewController,
        device: SimDeviceMetrics,
        orientation: Orientation,
        chromeHeight: CGFloat
    ) {
        // The pane VC's `udid` carries the backend-neutral identity key
        // (a UDID for a sim, a deviceId for a device), so the layout-tree
        // slot must match the pane's kind: a device pane lives under a
        // `.device` leaf, not `.sim`, and a `.sim`-keyed lookup would
        // miss it and silently no-op the preset.
        let slot: PaneSlot = pane.isPhysicalDevice
            ? .device(deviceId: pane.udid)
            : .sim(udid: pane.udid)
        guard let path = PaneTreeOps.path(to: slot, in: tree) else { return }
        guard let parent = locateParentSplit(forPath: path) else { return }
        let isVertical = (parent.axis == .horizontal)
        // The sim chrome strip sits at the TOP of the pane and
        // reduces the usable content area HEIGHT. In a vertical
        // split (side-by-side, divider runs vertically), the
        // chrome reduces the perpendicular (height); in a
        // horizontal split (top/bottom), the chrome reduces the
        // divided axis (also height). Fit Screen has to size the
        // device against the usable CONTENT area, because sizing against
        // the pane's full extent would either push the screen up
        // into the chrome or leave excess letterbox.
        let chromeOnPerpendicular: CGFloat = isVertical ? chromeHeight : 0
        let chromeOnDividedAxis: CGFloat = isVertical ? 0 : chromeHeight
        let availableExtent: CGFloat = (isVertical
            ? parent.splitView.bounds.width
            : parent.splitView.bounds.height) - chromeOnDividedAxis
        let perpendicularExtent: CGFloat = (isVertical
            ? parent.splitView.bounds.height
            : parent.splitView.bounds.width) - chromeOnPerpendicular
        let screenMetrics = MacScreenMetrics(
            backingScaleFactor: parent.splitView.window?.screen?.backingScaleFactor ?? 2.0,
            pointsPerInch: 110
        )
        // Reserve perpendicular room for the device-frame bezel so
        // Fit Screen doesn't push the screen edge-to-edge against
        // the pane boundary (which clips the bezel sublayer). Use
        // the family's max possible inset. Over-reserving by a
        // few points is fine; under-reserving clips the bezel.
        let bezelReserve = DeviceBezelLayoutMath.maxBezelInset(family: device.family)
        guard let screenTarget = SimSizeMath.targetWidth(
            preset: preset,
            device: device,
            screen: screenMetrics,
            availableWidth: availableExtent,
            axisIsVertical: isVertical,
            perpendicularExtent: perpendicularExtent,
            orientation: orientation,
            bezelReserve: bezelReserve
        ) else { return }
        // Add chrome back when it eats the divided axis (horizontal
        // split), where the final pane extent on the divided axis is
        // [chrome] + [content]. For vertical splits, chrome is in
        // the perpendicular axis and the divided-axis target is
        // already chrome-free.
        let target = screenTarget + chromeOnDividedAxis
        let floor = Self.simMinThickness(family: device.family, isVertical: isVertical)
        let pixels = max(floor, target)
        let dividerThickness = parent.splitView.dividerThickness
        // First-position sim: no divider sits before us, so the
        // "shrink toward the trailing edge" math doesn't apply.
        // Move the divider AFTER the pane (the divider between us and
        // the next sibling) to the pane's intended trailing edge,
        // which is `pixels` measured from the split's leading edge.
        if parent.indexInParent == 0 {
            guard parent.splitView.arrangedSubviews.count > 1 else { return }
            parent.splitView.setPosition(pixels, ofDividerAt: 0)
            parent.splitView.layoutSubtreeIfNeeded()
            captureRatios(for: parent.splitView)
            return
        }
        let trailingEdge: CGFloat
        if parent.indexInParent == parent.splitView.arrangedSubviews.count - 1 {
            // Divider positioning works in the split view's FULL
            // coordinate space; chrome was only subtracted from
            // `availableExtent` for the SIZING calc above. Using
            // the chrome-subtracted value here would place the
            // trailing edge one chrome-strip-height too far up
            // and the last pane would end up taller than the
            // split allows.
            trailingEdge = isVertical
                ? parent.splitView.bounds.width
                : parent.splitView.bounds.height
        } else {
            let paneView = parent.splitView.arrangedSubviews[parent.indexInParent]
            trailingEdge = isVertical ? paneView.frame.maxX : paneView.frame.maxY
        }
        let position = max(0, trailingEdge - dividerThickness - pixels)
        parent.splitView.setPosition(position, ofDividerAt: parent.indexInParent - 1)
        parent.splitView.layoutSubtreeIfNeeded()
        captureRatios(for: parent.splitView)
    }

    private func locateParentSplit(forPath path: [Int]) -> ParentSplit? {
        guard !path.isEmpty,
            let rootView = view.subviews.first as? NSSplitView else { return nil }
        var current: NSSplitView = rootView
        var currentNode: PaneNode = tree
        for childIndex in path.dropLast() {
            guard case let .split(_, children, _) = currentNode,
                childIndex < children.count,
                childIndex < current.arrangedSubviews.count,
                let nextSplit = current.arrangedSubviews[childIndex] as? NSSplitView else {
                return nil
            }
            current = nextSplit
            currentNode = children[childIndex]
        }
        guard case let .split(axis, _, _) = currentNode else { return nil }
        return ParentSplit(splitView: current, indexInParent: path.last ?? 0, axis: axis)
    }

    // MARK: - Reset Pane Layout

    @objc
    func resetPaneLayout(_ sender: Any?) {
        resetLayout()
    }

    // MARK: - @objc Size preset selectors (responder-chain fallback)

    @objc
    func applySizePresetPhysical(_ sender: Any?) {
        targetedSimPane()?.applySizePreset(.physical)
    }

    @objc
    func applySizePresetPointAccurate(_ sender: Any?) {
        targetedSimPane()?.applySizePreset(.pointAccurate)
    }

    @objc
    func applySizePresetPixelAccurate(_ sender: Any?) {
        targetedSimPane()?.applySizePreset(.pixelAccurate)
    }

    @objc
    func applySizePresetFitScreen(_ sender: Any?) {
        targetedSimPane()?.applySizePreset(.fitScreen)
    }

    @objc
    func toggleAxInspector(_ sender: Any?) {
        targetedSimPane()?.toggleAxInspector(sender)
    }

    // The device-control menu-bar fallbacks (`pressHardwareHome`,
    // `rebootDevice`, `screenshotPane`, …) live in the `+DeviceMenu`
    // file; they forward to `targetedSimPane()`. Their enablement is
    // gated here in `validateUserInterfaceItem`.

    func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        guard let action = item.action else { return true }
        // ⌘W names what it would close, so the user reads the
        // consequence before committing to it. Resolved on every
        // validation pass because focus moves between them.
        if action == #selector(closeFocusedPaneOrTab(_:)), let menuItem = item as? NSMenuItem {
            menuItem.title = PaneCloseTargetDecision.menuTitle(for: closeTarget())
        }
        if action == #selector(recordPane(_:)), let menuItem = item as? NSMenuItem {
            let target = targetedSimPane()
            menuItem.title = target?.recordingProcess == nil
                ? "Record Screen"
                : "Stop Recording"
        }
        // Scope gate, ahead of the affordance gate below. Arriving here
        // at all means the focused pane declined the selector, so no
        // device pane holds focus. A device-scoped chord pressed in that
        // state belongs to whatever the user is typing into, and AppKit
        // hands a disabled item's event down to it rather than eating
        // the key. Clicking the same item forwards to the tab's first
        // device pane.
        if let entry = KeybindingCatalog.entry(forSelector: action, tag: item.tag) {
            let origin = DeviceShortcutScopeDecision.origin(
                currentEvent: NSApp.currentEvent,
                chord: entry.chord
            )
            guard DeviceShortcutScopeDecision.fallbackAllows(
                scope: entry.scope,
                origin: origin
            ) else {
                return false
            }
        }
        // The responder-chain fallback for the menu-bar items: gate each
        // device-control selector on the *targeted* pane's capabilities
        // + kind through the same shared rule the focused VC uses, so a
        // physical-device pane disables the simulator-only actions while
        // keeping the ones it supports. No targeted pane → a gated
        // selector is disabled; unmanaged selectors are left enabled.
        guard let affordance = PaneControlAffordance.forSelector(action) else {
            return true
        }
        guard let target = targetedSimPane() else { return false }
        return affordance.isEnabled(
            capabilities: target.capabilities,
            isPhysicalDevice: target.isPhysicalDevice,
            family: DeviceFamily(wire: target.family)
        )
    }

    /// `internal` (not `private`): the device-menu forwarders in the
    /// `+DeviceMenu` file route through this.
    func targetedSimPane() -> SimulatorPaneViewController? {
        if let focused = focusedPaneViewController() as? SimulatorPaneViewController {
            return focused
        }
        return simPanes.first
    }

    private func focusedPaneViewController() -> NSViewController? {
        guard let slot = focusedSlot() else { return nil }
        return paneVCs[slot]
    }

    /// The slot whose pane currently holds keyboard focus.
    ///
    /// Asks which pane *contains* the first responder rather than
    /// walking up the responder chain looking for known VC types. The
    /// real first responder is always a descendant (libghostty's surface
    /// for a terminal, the Metal view for a device), so containment is
    /// the relation that decides it, and asking that way also names a
    /// focused pending placeholder, which a type-matching walk cannot.
    /// Panes are siblings in a split, so at most one can match.
    ///
    /// `internal` (not `private`): the pane-navigation and split
    /// forwarders in the `+PaneNavigation` / `+Split` files resolve the
    /// origin pane through this.
    func focusedSlot() -> PaneSlot? {
        for (slot, paneVC) in paneVCs where paneVC.view.containsFirstResponder() {
            return slot
        }
        return nil
    }

    /// Every leaf's frame in one coordinate space, the controller's own
    /// root view. Directional focus resolves neighbors against this
    /// rather than against the tree: `PaneNode.split` carries `extents`,
    /// but those are seeds that a divider drag never updates, so a
    /// tree-only answer would point at proportions the user cannot see.
    ///
    /// Keys on the pane's slot frame, not its rendered content. A device
    /// pane letterboxes its screen inside the slot, and the slot is what
    /// the user is aiming at.
    func slotFrames() -> [PaneSlot: CGRect] {
        var frames: [PaneSlot: CGRect] = [:]
        for (slot, paneVC) in paneVCs {
            let paneView = paneVC.view
            guard paneView.superview != nil else { continue }
            frames[slot] = paneView.convert(paneView.bounds, to: view)
        }
        return frames
    }
}

extension PaneLayoutViewController: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        // The notification fires for both user divider drags and
        // window resize, so we capture proportions either way. The
        // resulting ratios feed `applyRatios` on the next layout
        // pass, which is what preserves a manually-resized layout
        // until the user (or auto-rebalance) changes it again.
        //
        // Skip capture while applyRatios is in flight: the rebuild
        // window's transient zero-bounds frames would write a
        // garbage 1/0 ratio over the freshly-computed natural-extent
        // 50/50 (or proportional) ratios. See `PaneRatioStore.isApplying`.
        // Also skip until the first post-reconcile layout applies the
        // seed (`awaitingFirstApply`): the first real layout of a rebuilt
        // split distributes a reused sibling's old extent against a
        // brand-new sibling's minimum, and capturing that would clobber
        // the seed before `applyRatios` gets to apply it.
        guard !ratioStore.isApplying, !awaitingFirstApply else { return }
        guard let split = notification.object as? NSSplitView else { return }
        captureRatios(for: split)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMin: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let minThickness = minThickness(
            forSubview: dividerIndex,
            in: splitView,
            isLowerEdge: true
        )
        return proposedMin + minThickness
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMax: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let minThickness = minThickness(
            forSubview: dividerIndex + 1,
            in: splitView,
            isLowerEdge: false
        )
        return proposedMax - minThickness
    }

    private func minThickness(
        forSubview index: Int,
        in splitView: NSSplitView,
        isLowerEdge: Bool
    ) -> CGFloat {
        let isVertical = splitView.isVertical
        guard splitView.arrangedSubviews.indices.contains(index) else {
            return 80
        }
        _ = isLowerEdge
        return recursiveMinThickness(
            view: splitView.arrangedSubviews[index],
            isVertical: isVertical
        )
    }

    /// Recursive minimum-extent aggregation across a subview's
    /// descendants along the parent split's divider axis. For a leaf
    /// pane VC the answer is the pane's own per-axis floor. For a
    /// nested NSSplitView:
    ///   - if the nested split's own axis matches the parent's, its
    ///     children share the constrained axis → SUM of child mins;
    ///   - if axes differ, the nested split's children stack
    ///     perpendicular → every child must fit the full parent-axis
    ///     extent → MAX of child mins.
    ///
    /// Without this, the delegate returned the first pane VC found in
    /// dictionary-iteration order, so a sibling with a larger minimum
    /// would silently be crushed below its floor when the user dragged
    /// the parent divider.
    private func recursiveMinThickness(view: NSView, isVertical: Bool) -> CGFloat {
        for (slot, paneVC) in paneVCs where paneVC.view === view {
            switch slot {
            case .terminal:
                return Self.terminalMinThickness(isVertical: isVertical)

            case .sim, .device:
                let family = (paneVC as? SimulatorPaneViewController)
                    .map { DeviceFamily(wire: $0.family) } ?? .unknown
                return Self.simMinThickness(family: family, isVertical: isVertical)

            case .pending:
                let family = (paneVC as? PendingPaneViewController)
                    .map { DeviceFamily(wire: $0.family) } ?? .unknown
                return Self.simMinThickness(family: family, isVertical: isVertical)
            }
        }
        guard let nested = view as? NSSplitView else {
            // The view isn't a known pane root yet, which happens during
            // hierarchy rebuild before child VCs reattach. The 80pt
            // fallback keeps drag math sane until the next layout
            // pass refills the registry.
            return 80
        }
        let nestedExtents = nested.arrangedSubviews.map {
            recursiveMinThickness(view: $0, isVertical: isVertical)
        }
        if nestedExtents.isEmpty { return 80 }
        if nested.isVertical == isVertical {
            return nestedExtents.reduce(0, +)
        }
        return nestedExtents.max() ?? 80
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

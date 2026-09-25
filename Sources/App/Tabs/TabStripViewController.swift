// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol

/// One window's tab strip + content swap,
/// driven by observing its TabListViewModel. Menu actions dispatch routes
/// through the Router instead of mutating tabs directly; the strip + the
/// selected content view reconcile from state. The Detach/Shut-Down
/// prompt stays here (CloseDecisions): the Router consumes whatever mode
/// the user picks. When the tab list goes empty (close last tab), the
/// window asks AppKit to close, which routes through `windowWillClose`.
@MainActor
final class TabStripViewController: NSViewController, NSUserInterfaceValidations {
    /// Maximum width for a solo tab so it doesn't stretch across half
    /// the window. 480pt gives a single tab room to read at a glance.
    static let soloPillMaxConstant: CGFloat = 480

    /// Opacity of a pill while it's the one being dragged: it slides to
    /// its target slot dimmed so the user sees where it will land.
    private static let draggedPillAlpha: CGFloat = 0.4

    /// Diagnostic accessor for the live tab count (the --smoke probe).
    var tabCount: Int { tabListVM.tabs.count }

    private let windowID: WindowID
    private let tabListVM: TabListViewModel
    private let daemonClient: any DaemonClienting
    private let paneResurrect: PaneResurrect
    private let router: Router

    /// Names of the configured automation programs a tab runs that
    /// supervision is still keeping alive. Injected because supervision is
    /// the app's, not the strip's, and the strip only needs the names.
    var hostsAutomationProgram: (@MainActor (TabID) -> [String])?
    private var tabContentByID: [TabID: TabContentViewController] = [:]
    /// Lightweight content for a tab whose initial daemon session failed to
    /// mint. It keeps the committed tab visible and closable without ever
    /// provisioning a shell for the sentinel model terminal.
    private var failedTabContentByID: [TabID: NSViewController] = [:]
    /// Outer drag-source row: `[cellsContainer, addButton]`. Empty
    /// regions report `mouseDownCanMoveWindow = true` so click-and-drag
    /// on background moves the window (the strip is mounted in the
    /// title-bar region thanks to `.fullSizeContentView`).
    private var strip = DraggableStackView()
    /// Holds the per-tab cells (`[×, marker?, title]` stacks) under
    /// `.fillEqually` distribution so multi-tab widths are equal by
    /// construction without cross-cell `equalTo` constraints that would
    /// outlive cells during teardown. Also a
    /// DraggableStackView so click-and-drag on the empty space between
    /// pills still drags the window.
    private var cellsContainer = DraggableStackView()
    private var content = NSView()
    /// Activated only when 2+ tabs are present, this constraint forces the
    /// strip to span the full window width so `.fillEqually` inside the
    /// cells container splits available width across the tabs. With one
    /// tab the constraint is inactive and the strip stays at its
    /// intrinsic width (cellsContainer capped at 480).
    private var stripFillTrailing: NSLayoutConstraint?
    /// Active when only one tab exists. Caps the lone pill at the
    /// solo-pill max so it doesn't stretch across the whole window.
    private var soloPillMaxWidth: NSLayoutConstraint?
    /// Active when only one tab exists. Pulls the lone pill TO the
    /// solo-pill max. Without this, the cell sits at its intrinsic
    /// title width with no floor to widen it. Held below the window-drag
    /// threshold (see `TabPillLayout`) so wanting that width never becomes
    /// the window's minimum width.
    private var soloPillTargetWidth: NSLayoutConstraint?
    /// The per-cell width the strip is holding while a run of ✕ closes is in
    /// progress, nil when not frozen. One value covers every cell, because
    /// `.fillEqually` gives them all the same width to begin with.
    private var frozenCellWidth: CGFloat?
    private var frozenWidthConstraints: [NSLayoutConstraint] = []
    /// Absorbs the width the closed pills released, so the survivors keep
    /// their frozen widths inside a strip that still spans the window. With
    /// nothing to take the slack, `.fill` would push it onto the pinned cells
    /// and break one.
    private let frozenTrailingSpacer = NSView()
    /// Thin translucent track that sits behind the tab cells so the
    /// user sees a visible "lane" the pills rest in. Painted with a
    /// low-alpha white tint over the window background, which gives
    /// predictable contrast in any colorspace (NSVisualEffectView
    /// materials introduce a warm tint in dark mode that reads as
    /// discolored over a neutral terminal background).
    private let tabTrack = NSView()
    private var observation: ObservationToken?
    /// Cross-window / tear-off relocation seam (see `TabTransferCoordinating`).
    /// Set by `AppDelegate` after construction; nil in unit contexts, where
    /// cross-window drops and tear-off are no-ops.
    weak var tabTransfer: (any TabTransferCoordinating)?
    /// The tab whose pill is being live-reordered within this strip, or
    /// nil when no same-window drag is in progress. While set, the
    /// arranged order of `cellsContainer` is ahead of the nav model; the
    /// drop commits it, a cancel/exit snaps it back.
    private var liveReorderTabID: TabID?
    /// Tab-id order at the last render, so we only rebuild the strip on
    /// structure change (not on every title-driven re-render).
    private var lastTabIDs: [TabID] = []
    /// Selected tab at the last render, so we only swap the content view
    /// and refocus the terminal on a *real* selection change. Without
    /// this, every OSC/CWD title update would steal first responder back
    /// to the terminal even when the user had focused a sim pane.
    private var lastSelectedID: TabID?

    /// Live tab content VCs to adopt at first render (a tear-off window
    /// is built holding the dragged tab's already-live VC). Seeded into
    /// `tabContentByID` in `viewDidLoad` *before* observation arms, so
    /// the synchronous first render skips the create branch instead of
    /// minting a fresh shell. Consumed once; empty for normal windows.
    private let adopting: [(TabID, TabContentViewController)]

    init(
        windowID: WindowID,
        tabListVM: TabListViewModel,
        daemonClient: any DaemonClienting,
        paneResurrect: PaneResurrect,
        router: Router,
        adopting: [(TabID, TabContentViewController)] = []
    ) {
        self.windowID = windowID
        self.tabListVM = tabListVM
        self.daemonClient = daemonClient
        self.paneResurrect = paneResurrect
        self.router = router
        self.adopting = adopting
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Name a tab's pill and closer so a dump can tell one tab from another:
    /// both carry display titles, which collide freely. The supplied short ID
    /// derives from the tab's cohort UUID, so it remains stable across terminal
    /// splits and primary-terminal promotion.
    static func applyAccessibilityIdentifiers(
        pill: NSButton,
        close: NSButton?,
        shortId: String?
    ) {
        pill.setAccessibilityIdentifier(shortId.map(TabAccessibilityIdentity.identifier(forTab:)))
        close?.setAccessibilityIdentifier(
            shortId.map(TabAccessibilityIdentity.closeIdentifier(forTab:))
        )
    }

    static func accessibilityShortID(for tab: TabState) -> String? {
        WorkspaceShortID.make(from: tab.cohortId)
    }

    /// The color a pill's text takes at a given selection state, shared by the
    /// title and the shortcut badge so the two dim together.
    ///
    /// Inactive tabs dim rather than the active one brightening, because
    /// `labelColor` is already the brightest semantic label color there is.
    /// Both are semantic, so they track the system appearance with no palette
    /// of our own to maintain.
    static func titleColor(isSelected: Bool) -> NSColor {
        isSelected ? .labelColor : .secondaryLabelColor
    }

    /// Paint a pill's title: the text, and the color that marks selection.
    ///
    /// Text and color are written together because assigning `title` discards
    /// any `attributedTitle`. Both passes that name a title call this, so
    /// neither can drop the other's color by running second.
    ///
    /// The paragraph style carries the button's truncation and alignment
    /// forward: an attributed title supplies its own, so the `lineBreakMode`
    /// set when the button was built stops reaching the text.
    static func applyTitleStyling(to button: NSButton, text: String, isSelected: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = button.alignment
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: titleColor(isSelected: isSelected),
                .paragraphStyle: paragraph
            ]
        )
    }

    override func loadView() {
        // Root reports mouseDownCanMoveWindow = true so the empty area
        // beside the strip (with one tab, the strip stays at intrinsic
        // ~520pt and the rest of the row is plain root background) still
        // drags the window. Without this, single-tab windows expose a
        // dead band across the integrated title bar. The view also
        // forwards effective-appearance changes so the selected pill's
        // CGColor snapshot gets repainted on a light/dark flip.
        let root = DraggableRootView()
        root.onEffectiveAppearanceChange = { [weak self] in
            guard let self else { return }
            self.applySelection(for: self.tabListVM.tabs)
            self.applyChromeTint()
        }

        // A run of ✕ closes holds the pill widths; the pointer leaving the
        // strip is what ends it and lets the survivors re-flow.
        strip.onPointerExit = { [weak self] in self?.thawCellWidths() }
        strip.orientation = .horizontal
        // 10pt spacing gives the new-tab "+" button breathing room from
        // the rightmost tab pill instead of cramming up against it.
        strip.spacing = 10
        strip.alignment = .centerY
        // `.fill` lets the cellsContainer (low hugging) absorb leftover
        // width while the addButton (required hugging, set below) stays
        // compact at the trailing edge.
        strip.distribution = .fill
        strip.translatesAutoresizingMaskIntoConstraints = false

        cellsContainer.orientation = .horizontal
        cellsContainer.spacing = 1
        cellsContainer.alignment = .centerY
        // `.fillEqually` divides the container's width across the cells.
        // For one tab the cell takes the whole container; for N≥2 each
        // cell is container.width / N, equal by construction.
        cellsContainer.distribution = .fillEqually
        cellsContainer.translatesAutoresizingMaskIntoConstraints = false
        // The container stretches to fill the strip's leftover space; the
        // "+" button hugs tight.
        cellsContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        content.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NewTabButton()
        addButton.target = self
        addButton.action = #selector(newTab(_:))
        // Keep "+" at its intrinsic width even when the strip stretches.
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        addButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Tab track: a translucent capsule sitting BEHIND the cells
        // container. Three-level hierarchy painted with explicit white
        // alphas (NSVisualEffectView materials introduce a warm tint
        // in dark mode that reads as discolored over a neutral
        // terminal background):
        //   - Track: ~5% white tint (faint lane)
        //   - Hover: ~10% (cell paints over track)
        //   - Selected: ~16% (clearly active)
        tabTrack.translatesAutoresizingMaskIntoConstraints = false
        tabTrack.wantsLayer = true
        // 14pt matches the cell pills' radius: same shape, different
        // alpha for each state.
        tabTrack.layer?.cornerRadius = 14
        tabTrack.layer?.cornerCurve = .continuous
        tabTrack.layer?.masksToBounds = true
        tabTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor

        root.addSubview(strip)
        root.addSubview(content)
        strip.addSubview(tabTrack, positioned: .below, relativeTo: nil)
        strip.addArrangedSubview(cellsContainer)
        strip.addArrangedSubview(addButton)

        // Tab strip sits BELOW the native title bar. With
        // `.fullSizeContentView` on, our root extends to the window's
        // top edge: `strip.top = root.top + 28` reserves the title-bar
        // height as an inset. Leading 6 because the traffic lights are
        // in the title bar above, not in this row.
        let fillTrailing = strip.trailingAnchor.constraint(
            equalTo: root.trailingAnchor,
            constant: -6
        )
        stripFillTrailing = fillTrailing

        // Solo-pill cap: only active when there's exactly one tab so the
        // lone cell doesn't stretch across half the window.
        let soloMax = cellsContainer.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.soloPillMaxConstant
        )
        soloPillMaxWidth = soloMax
        // Equal-to-constant: wants the solo pill at its full target
        // width; yields if a narrow window or stripFill contradicts.
        let soloTarget = cellsContainer.widthAnchor.constraint(
            equalToConstant: Self.soloPillMaxConstant
        )
        soloTarget.priority = TabPillLayout.soloPillTarget
        soloPillTargetWidth = soloTarget

        NSLayoutConstraint.activate(
            [
            strip.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            strip.trailingAnchor.constraint(
                lessThanOrEqualTo: root.trailingAnchor,
                constant: -6
            ),
            strip.heightAnchor.constraint(equalToConstant: 34),
            // Force the cells container to fill the strip's height.
            // Without this, NSStackView sizes it to its tallest
            // arranged subview, collapsing it to ~28pt and making
            // the track inset math go negative.
            cellsContainer.heightAnchor.constraint(equalTo: strip.heightAnchor),
            // Track sits at 3pt top/bottom inset = 28pt height,
            // exactly matching the cells (which centerY-align in the
            // 34pt container at 28pt intrinsic).
            tabTrack.topAnchor.constraint(equalTo: cellsContainer.topAnchor, constant: 3),
            tabTrack.bottomAnchor.constraint(equalTo: cellsContainer.bottomAnchor, constant: -3),
            tabTrack.leadingAnchor.constraint(equalTo: cellsContainer.leadingAnchor),
            tabTrack.trailingAnchor.constraint(equalTo: cellsContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: strip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ]
            )
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for name in [
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(frameDemandChanged(_:)), name: name, object: nil
            )
        }
        // Seed adopted (torn-off) tab VCs before observation arms, so the
        // first synchronous render finds them already present and doesn't
        // build a fresh content VC (which would spawn a new shell).
        for (id, tabContent) in adopting {
            tabContent.rebind(to: tabListVM, windowID: windowID)
            addChild(tabContent)
            tabContentByID[id] = tabContent
            wireTerminalExit(of: tabContent)
        }
        observation = App.observe { [weak self] in self?.render() }
        // Accept tab drags over the cells lane: reorder within this
        // window, and adopt a tab dragged from another window.
        cellsContainer.dropDelegate = self
        cellsContainer.registerForDraggedTypes(
            [NSPasteboard.PasteboardType(TabDragPayload.pasteboardType)]
        )
        applyChromeTint()
    }

    /// A strip that leaves its window stops getting pointer events, so the
    /// exit that would have ended a frozen run never arrives. Release here
    /// instead of letting the widths outlive the gesture.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        for tab in tabContentByID.values { tab.setSimulatorFrameDemand(false) }
        thawCellWidths()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reconcileFrameDemand()
        // observe() arms synchronously, so the first render() ran from
        // viewDidLoad with no window attached and its title / proxy-icon writes
        // went nowhere. Reapply now that the strip is in a window: an adopted
        // tear-off tab carries its label and OSC-7 path across with it, so no
        // further event is necessarily coming to trigger another pass.
        guard let index = tabListVM.selectedIndex,
            tabListVM.tabs.indices.contains(index) else { return }
        let tab = tabListVM.tabs[index]
        if let tabContent = tabContentByID[tab.id] {
            applyWindowMetadata(for: tabContent)
        } else if failedTabContentByID[tab.id] != nil {
            view.window?.title = displayTitle(for: tab)
            view.window?.representedFilename = ""
        }
    }

    /// Sync the host window's `backgroundColor` to the ghostty
    /// `background` config color. With `titlebarAppearsTransparent =
    /// true` + `.fullSizeContentView` on (set in WindowController),
    /// the title bar AND the empty area behind the tab strip both
    /// show the window's bg color, so painting once at the window
    /// level unifies both surfaces. The
    /// `DraggableRootView.onEffectiveAppearanceChange` hook calls
    /// back into this path so the tint refreshes on a light/dark
    /// flip without going stale.
    private func applyChromeTint() {
        if let tint = GhosttyThemeColors.cachedBackground() {
            view.window?.backgroundColor = tint
        }
    }

    /// Called by AppDelegate when a window is going away (red-X close or
    /// quit-driven reconcile drop). Runs the per-tab teardown (cancel
    /// observation/discovery, close the libghostty surface, unwatch
    /// PaneResurrect) before the controller drops out of the AppKit tree.
    func teardown() {
        observation?.cancel()
        observation = nil
        for tabContent in tabContentByID.values {
            tabContent.teardown()
        }
        tabContentByID.removeAll()
        failedTabContentByID.removeAll()
    }

    // MARK: - Cross-window tab transfer (live-VC relocation)
    //
    // The transfer coordinator (AppDelegate) calls extract → adopt as one
    // synchronous block, moving the `TabState` between the two windows'
    // `TabListViewModel`s in between. Because `observe()` re-arms on the
    // next main-actor turn, neither strip's `render()` runs mid-transfer,
    // so the moved VC is never torn down or re-created: the dict already
    // matches each VM by the time either strip re-renders.

    /// Detach a tab's **live** content VC from this strip WITHOUT
    /// teardown (no libghostty close / shell kill): drop the dict entry,
    /// remove the child VC, and unmount its view. Returns the instance
    /// for the destination strip to adopt. Nil when the tab isn't hosted
    /// here.
    func extractTabContent(id: TabID) -> TabContentViewController? {
        guard let tabContent = tabContentByID.removeValue(forKey: id) else { return nil }
        tabContent.removeFromParent()
        if tabContent.isViewLoaded {
            tabContent.view.removeFromSuperview()
        }
        return tabContent
    }

    /// Adopt a live content VC extracted from another window's strip:
    /// rebind it to this window's nav state, re-parent it, and re-wire
    /// its terminal-exit handler to this strip. The next (async) render
    /// skips the create branch and builds the pill; `applySelection`
    /// mounts the view when the adopted tab becomes selected.
    func adoptTabContent(_ tabContent: TabContentViewController, for id: TabID) {
        tabContent.rebind(to: tabListVM, windowID: windowID)
        addChild(tabContent)
        tabContentByID[id] = tabContent
        wireTerminalExit(of: tabContent)
    }

    // MARK: - Menu actions
    //
    // AppKit actions already hold concrete GUI IDs, so they dispatch Routes
    // directly. Only external workspace commands pass through RouteIntent and
    // its public-ref resolver.

    @objc
    func newTab(_ sender: Any?) {
        router.dispatch(.newTab(windowID))
    }

    /// Shell → "Open Automation Tab". The product-UI path for
    /// minting a session with `.automation` role; no CLI verb
    /// emits this. The CLI back-channel encodes role as a string;
    /// menu emissions pass the typed `.automation` enum directly.
    @objc
    func openAutomationTab(_ sender: Any?) {
        router.dispatch(.openAutomationTab(windowID))
    }

    /// ⌥⌘W / Shell → Close Tab on the current selection.
    @objc
    func closeTab(_ sender: Any?) {
        guard let index = tabListVM.selectedIndex,
            let tab = tabListVM.tabs[safe: index] else { return }
        requestCloseTab(id: tab.id)
    }

    /// The ⌘W fallback, name-identical to `PaneLayoutViewController`'s so the
    /// two form one chain for a single menu item. The layout controller
    /// sits below this one and claims the selector whenever a pane holds
    /// focus. Focus elsewhere in the window, a tab pill under full
    /// keyboard access, leaves the layout controller out of the chain
    /// entirely, and the search arrives here. There is no focused pane to
    /// name in that case, which is the tab.
    @objc
    func closeFocusedPaneOrTab(_ sender: Any?) {
        closeTab(sender)
    }

    /// Titles the ⌘W item for the fallback above. Without this the item
    /// would keep whichever title the layout controller last gave it and
    /// could read "Close Pane" while closing the tab.
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(closeFocusedPaneOrTab(_:)),
            let menuItem = item as? NSMenuItem {
            menuItem.title = PaneCloseTargetDecision.menuTitle(for: .tab)
        }
        return true
    }

    @objc
    private func closeTabFromButton(_ sender: NSButton) {
        let tabID = TabID(value: sender.tag)
        if TabWidthFreezeDecision.shouldFreeze(
            origin: .closeButton,
            pointerIsOverStrip: pointerIsOverStrip()
        ) {
            freezeCellWidths()
        }
        requestCloseTab(id: tabID)
    }

    /// Whether the pointer is over the strip right now, asked of the window
    /// rather than of the event: a ✕ activated through accessibility sends the
    /// same action with the pointer wherever it happens to be.
    private func pointerIsOverStrip() -> Bool {
        guard let window = view.window else { return false }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return strip.bounds.contains(strip.convert(inWindow, from: nil))
    }

    /// Sample the width every cell currently has, and keep it until thawed.
    ///
    /// Repeated calls keep the width the first one captured: the point of a
    /// run is that nothing moves until the pointer leaves.
    private func freezeCellWidths() {
        guard frozenCellWidth == nil else { return }
        guard let cell = cellsContainer.arrangedSubviews.first as? TabPillCell,
            cell.frame.width > 0 else { return }
        frozenCellWidth = cell.frame.width
    }

    /// Pin the rebuilt cells to the frozen width and park the spacer after
    /// them. Runs at the end of every rebuild, because a close tears the cells
    /// down and builds new ones that carry none of this.
    ///
    /// The pins outrank each cell's 180pt floor, so the run survives a rebuild
    /// at the width it started from, and sit below the window-drag threshold,
    /// so narrowing the window past the frozen row ends the run's geometry
    /// rather than the resize.
    private func applyFrozenCellWidths() {
        guard let width = frozenCellWidth else { return }
        cellsContainer.distribution = .fill
        for case let cell as TabPillCell in cellsContainer.arrangedSubviews {
            let pin = cell.widthAnchor.constraint(equalToConstant: width)
            pin.priority = TabPillLayout.frozenWidthPin
            pin.isActive = true
            frozenWidthConstraints.append(pin)
        }
        frozenTrailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        frozenTrailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        frozenTrailingSpacer.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        cellsContainer.addArrangedSubview(frozenTrailingSpacer)
    }

    /// The count-driven width policy: span the window with two or more tabs,
    /// take the solo cap with one.
    ///
    /// Deferred while frozen, because closing down to a single tab applies it
    /// mid-run otherwise. Dropping the full-width constraint moves the "+" and
    /// the track's trailing edge, and the solo cap is required, so it outranks
    /// the frozen pins and snaps a pill wider than 480pt narrower. Both land
    /// under a pointer that has not moved, and the next click in a run can
    /// then hit the "+" instead of a ✕.
    private func applyStripWidthPolicy(tabCount: Int) {
        stripFillTrailing?.isActive = tabCount >= 2
        soloPillMaxWidth?.isActive = tabCount == 1
        soloPillTargetWidth?.isActive = tabCount == 1
    }

    /// Release the widths and let the strip re-flow. Idempotent, since several
    /// unrelated events can each be the one that ends a run.
    private func thawCellWidths() {
        guard frozenCellWidth != nil else { return }
        frozenCellWidth = nil
        NSLayoutConstraint.deactivate(frozenWidthConstraints)
        frozenWidthConstraints.removeAll()
        if frozenTrailingSpacer.superview != nil {
            cellsContainer.removeArrangedSubview(frozenTrailingSpacer)
            frozenTrailingSpacer.removeFromSuperview()
        }
        cellsContainer.distribution = .fillEqually
        // The policy the freeze deferred, now against the strip as it stands.
        applyStripWidthPolicy(tabCount: tabListVM.tabs.count)
    }

    /// Window → Move Tab Left / Right (⌃⇧← / ⌃⇧→): shift the selected
    /// tab one slot. Distinct from the pane ⌘⇧← / ⌘⇧→ so the two never
    /// collide. The selectors reach this strip VC through the key
    /// window's responder chain (it sits above the focused pane).
    ///
    /// The tab's identity is captured here, since that is what the user
    /// pointed at, but its index is left for the drain to resolve. Sending
    /// a destination index would give every press queued behind an
    /// in-flight route the same target, so a run of presses would shift
    /// the tab one slot in total.
    @objc
    func moveSelectedTabLeft(_ sender: Any?) { moveSelectedTab(by: -1) }

    @objc
    func moveSelectedTabRight(_ sender: Any?) { moveSelectedTab(by: +1) }

    private func moveSelectedTab(by delta: Int) {
        guard let tab = tabListVM.selectedTab else { return }
        router.dispatch(.moveTabRelative(windowID, tab.id, delta: delta))
    }

    @objc
    private func selectTabFromButton(_ sender: NSButton) {
        let tabID = TabID(value: sender.tag)
        guard tabListVM.tab(id: tabID) != nil else { return }
        router.dispatch(.selectTab(windowID, tabID))
    }

    // Window → tab navigation. These live in the main file rather than an
    // extension because `tabListVM` and `dispatchIntent` are both private;
    // relaxing two members to host a handful of forwarders would widen the
    // type's surface for no gain. Index arithmetic is in
    // `TabSelectionMath` so its edge cases are unit-tested.
    //
    // Next / Previous dispatch a route directly rather than an intent, as
    // Move Tab Left / Right already do. The intent layer exists to resolve
    // refs against an origin, and a relative offset carries no ref; there
    // is no CLI verb behind these either.

    /// Window → Tab 1 through Tab 8 (⌘1 through ⌘8). The item's `tag`
    /// carries the 1-based position, mirroring its label.
    @objc
    func selectTabByIndex(_ sender: NSMenuItem) {
        selectTab(
            at: TabSelectionMath.index(
                forMenuTag: sender.tag,
                tabCount: tabListVM.tabs.count
            )
        )
    }

    /// Window → Last Tab (⌘9).
    @objc
    func selectLastTab(_ sender: Any?) {
        selectTab(at: TabSelectionMath.lastIndex(tabCount: tabListVM.tabs.count))
    }

    /// Window → Select Previous Tab (⇧⌘[), wrapping to the last tab.
    @objc
    func selectPreviousTab(_ sender: Any?) {
        router.dispatch(.selectRelativeTab(windowID, delta: -1))
    }

    /// Window → Select Next Tab (⇧⌘]), wrapping to the first tab.
    @objc
    func selectNextTab(_ sender: Any?) {
        router.dispatch(.selectRelativeTab(windowID, delta: +1))
    }

    /// Dispatches the selection for a resolved index. A nil index means no
    /// tab answers the chord, which is a deliberate no-op.
    ///
    /// Resolves an absolute position to a concrete session before the
    /// asynchronous intent dispatch, so a repeat re-selects the same tab
    /// rather than losing a step. Relative selection cannot resolve here;
    /// it goes through `Route.selectRelativeTab` so that queued presses
    /// observe the selections preceding them.
    private func selectTab(at index: Int?) {
        guard let index, let tab = tabListVM.tabs[safe: index] else { return }
        router.dispatch(.selectTab(windowID, tab.id))
    }

    @objc
    func renameTabFromMenu(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? TabID else { return }
        presentRenameSheet(for: tabID)
    }

    /// Window → Rename Tab…, which renames the *selected* tab.
    ///
    /// A main-menu item carries no represented object, so it cannot use
    /// the right-click path above: that one resolves which tab from what
    /// the user pointed at, and a static item points at nothing.
    @objc
    func renameSelectedTab(_ sender: Any?) {
        guard let tab = tabListVM.selectedTab else { return }
        presentRenameSheet(for: tab.id)
    }

    private func presentRenameSheet(for tabID: TabID) {
        guard let tabContent = tabContentByID[tabID],
            let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText =
            "Enter a name for this tab. Leave it empty to restore the automatic title."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = tabContent.manualTitle ?? ""
        field.placeholderString = tabContent.displayTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak tabContent] response in
            guard response == .alertFirstButtonReturn, let tabContent else { return }
            tabContent.renameManually(to: field.stringValue)
        }
    }

    /// Apply a rename to the named tab without going through the
    /// modal sheet (which is the human-interactive path in
    /// `renameTabFromMenu`). Driven by the intent layer when a
    /// programmatic source such as CLI `deviceterm tab rename` asks for
    /// a rename. Passing nil or the empty string
    /// restores the automatic title (matches
    /// `TabTitleViewModel.renameManually`'s "empty → auto" behavior).
    /// Silently no-ops when the tab is no longer present, which is
    /// the natural concurrent outcome (caller dispatched, tab closed
    /// before the route landed).
    func renameTab(id tabID: TabID, to name: String?) {
        guard let tabContent = tabContentByID[tabID] else { return }
        tabContent.renameManually(to: name ?? "")
    }

    func sendInput(
        toTerminal terminalID: TerminalPaneID,
        inTab tabID: TabID,
        text: String,
        typeDelayMillis: Int?
    ) throws {
        guard let tabContent = tabContentByID[tabID] else {
            throw IntentError.notFound(kind: "tab", ref: "\(tabID.value)")
        }
        try tabContent.sendInput(
            to: terminalID,
            text: text,
            typeDelayMillis: typeDelayMillis
        )
    }

    /// When the tab attempted the first send of its configured automation
    /// command, or nil before any attempt. Read by supervision, which must
    /// not mistake a tab still waiting for its grant for a program that died.
    func automationCommandSentAt(inTab tabID: TabID) -> UInt64? {
        tabContentByID[tabID]?.automationCommandSentAt
    }

    func captureTerminal(
        _ terminalID: TerminalPaneID,
        inTab tabID: TabID,
        ansi: Bool
    ) throws -> String {
        guard let tabContent = tabContentByID[tabID] else {
            throw IntentError.notFound(kind: "tab", ref: "\(tabID.value)")
        }
        return try tabContent.captureTerminal(terminalID, ansi: ansi)
    }

    func focusPane(_ slot: PaneSlot, inTab tabID: TabID) {
        tabListVM.select(id: tabID)
        tabContentByID[tabID]?.focusPane(slot)
    }

    func displayTitle(for tabID: TabID) -> String? { tabContentByID[tabID]?.displayTitle }

    func terminalFacts(
        for terminalID: TerminalPaneID,
        inTab tabID: TabID,
        includeWorkingDirectory: Bool
    ) -> TerminalPaneFacts? {
        tabContentByID[tabID]?.terminalFacts(
            for: terminalID,
            includeWorkingDirectory: includeWorkingDirectory
        )
    }

    func focusedPane(inTab tabID: TabID) -> PaneSlot? {
        tabContentByID[tabID]?.focusedPane()
    }

    func lifecycle(for slot: PaneSlot, inTab tabID: TabID) -> PaneLifecycle? {
        tabContentByID[tabID]?.lifecycle(for: slot)
    }

    func orientation(for slot: PaneSlot, inTab tabID: TabID) -> Orientation? {
        tabContentByID[tabID]?.orientation(for: slot)
    }

    /// Repair an orphaned first responder in the selected tab, if it
    /// has one. Driven by `AppDelegate` when this strip's window takes
    /// key. Resolving through `tabListVM.selectedTab` rather than
    /// taking a TabID keeps the caller from having to know which tab is
    /// on screen, and matches what the user sees: only the visible
    /// tab's panes can be holding focus.
    func restoreFocusIfOrphaned() {
        guard let tabID = tabListVM.selectedTab?.id,
            let tabContent = tabContentByID[tabID] else { return }
        tabContent.restoreFocusIfOrphaned()
    }

    private func requestCloseTab(id tabID: TabID) {
        guard let tab = tabListVM.tab(id: tabID) else { return }
        guard !tab.primaryTerminal.sessionId.isEmpty else { return }
        // Router.closeTabRecords shuts down devices owned by ANY of
        // the tab's terminal sessions, not just the primary. Check
        // every one so a sim booted from a secondary terminal pane
        // doesn't skip the prompt and force-detach.
        let allSessionIDs = tab.terminals.map(\.sessionId).filter { !$0.isEmpty }
        let capturedWindowID = windowID
        // The skip-prompt decision can't trust `tab.simPanes`
        // (visible sim panes only) because a user can detach a pane
        // (the visual) without shutting down the sim, leaving the
        // session as the owner of a still-booted device. Asking the
        // daemon for the owned-booted set attributable to this tab's
        // sessions is the only correct predicate; do it async then
        // route back to the main actor for the prompt itself.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let affected = await self.daemonClient.hasOwnedBootedSims(
                forSessions: allSessionIDs
            )
            // Re-read the tab after the await: the main actor yielded
            // while the daemon answered, so panes may have been added
            // or removed, or the tab closed outright. The multi-pane
            // gate and the prompt use the current layout; the
            // sim-ownership answer still reflects the sessions
            // captured at the gesture.
            guard let tab = self.tabListVM.tab(id: tabID) else { return }
            let paneCount = PaneTreeOps.leavesInOrder(tab.paneTree).count
            let config = ConfigFile()
            let pinned = affected
                ? CloseSuppressionState.shared.lookupClose(
                    windowID: capturedWindowID,
                    config: config
                )
                : nil
            let context = CloseContext(
                windowID: capturedWindowID,
                hasOtherTabsInWindow: self.tabListVM.tabs.count > 1
            )
            let programs = self.hostsAutomationProgram?(tabID) ?? []
            switch TabCloseGateDecision.gate(
                simsAffected: affected,
                pinnedSimDecision: pinned,
                multiPane: paneCount > 1,
                programsAffected: !programs.isEmpty
            ) {
            case .simDisposition:
                // `tabClose` re-runs the lookup that just returned nil;
                // both reads happen in this same main-actor turn, so it
                // still misses and the prompt shows.
                let decision = await CloseDecisions.tabClose(
                    config: config,
                    state: CloseSuppressionState.shared,
                    context: context,
                    window: self.view.window,
                    whileTargetLives: { [weak self] in
                        self?.tabListVM.tab(id: tabID) != nil
                    }
                )
                // Awaiting the sheet frees the main actor, so the tab
                // can close while the prompt is visible. Re-read before
                // acting on an answer about it; the pane path does the
                // same after its own prompt.
                guard self.tabListVM.tab(id: tabID) != nil else { return }
                switch decision {
                case .detach:
                    self.router.dispatch(.closeTab(self.windowID, tabID, mode: .detach))

                case .shutdown:
                    self.router.dispatch(.closeTab(self.windowID, tabID, mode: .shutdown))

                case .cancel:
                    return
                }

            case let .programConfirm(mode):
                if await CloseDecisions.programTabClose(
                    names: programs,
                    window: self.view.window,
                    whileTargetLives: { [weak self] in
                        self?.tabListVM.tab(id: tabID) != nil
                    }
                ) {
                    // The sheet frees the main actor, so re-read the tab
                    // before acting on an answer about it, exactly as the
                    // other prompting arms do.
                    guard self.tabListVM.tab(id: tabID) != nil else { return }
                    self.router.dispatch(.closeTab(self.windowID, tabID, mode: mode))
                }

            case let .multiPaneConfirm(mode):
                if await CloseDecisions.multiPaneTabClose(
                    config: config,
                    state: CloseSuppressionState.shared,
                    context: context,
                    paneCount: paneCount,
                    window: self.view.window,
                    whileTargetLives: { [weak self] in
                        self?.tabListVM.tab(id: tabID) != nil
                    }
                ) {
                    guard self.tabListVM.tab(id: tabID) != nil else { return }
                    self.router.dispatch(.closeTab(self.windowID, tabID, mode: mode))
                }

            case let .close(mode):
                self.router.dispatch(.closeTab(self.windowID, tabID, mode: mode))
            }
        }
    }

    /// Bulk-close path for "Close Other Tabs" / "Close Tabs to the
    /// Right". Resolves the close decision ONCE before dispatching:
    /// pressing Cancel in whichever prompt runs aborts the whole
    /// operation, and the resolved Detach/Shutdown mode applies
    /// uniformly to every tab in `ids`. Sessions are snapshot before
    /// the dispatch loop so a mid-loop dispatch can't shift indices
    /// under us.
    private func requestBulkCloseTabs(ids: [TabID]) {
        let initialTargets = ids.compactMap { tabListVM.tab(id: $0) }
            .filter { !$0.primaryTerminal.sessionId.isEmpty }
        guard !initialTargets.isEmpty else { return }
        // Per-tab dispatch keys off the primary session (the existing
        // close-tab intent shape), but the affected-check sweeps every
        // terminal pane's session across every targeted tab, the same
        // correctness rule as `requestCloseTab`.
        let allSessionIDs = initialTargets.flatMap { $0.terminals.map(\.sessionId) }
            .filter { !$0.isEmpty }
        let capturedWindowID = windowID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let affected = await self.daemonClient.hasOwnedBootedSims(
                forSessions: allSessionIDs
            )
            // Re-resolve the targets after the await (same reason as
            // `requestCloseTab`): tabs may have closed and panes moved
            // while the daemon answered.
            let targets = ids.compactMap { self.tabListVM.tab(id: $0) }
                .filter { !$0.primaryTerminal.sessionId.isEmpty }
            guard !targets.isEmpty else { return }
            let sessionIDs = targets.map(\.primaryTerminal.sessionId)
            let multiPaneTabCount = targets
                .filter { PaneTreeOps.leavesInOrder($0.paneTree).count > 1 }
                .count
            let config = ConfigFile()
            let pinned = affected
                ? CloseSuppressionState.shared.lookupClose(
                    windowID: capturedWindowID,
                    config: config
                )
                : nil
            // Bulk close keeps at least one tab open (the user
            // right-clicked a tab and chose "Close Others" / "Close
            // Tabs to the Right"), so by definition other tabs remain
            // in the window after the operation: qualifies for the
            // per-window scope default.
            let context = CloseContext(
                windowID: capturedWindowID,
                hasOtherTabsInWindow: true
            )
            // Every program across the batch, so one prompt names all of
            // them rather than one per tab.
            let programs = targets.flatMap { self.hostsAutomationProgram?($0.id) ?? [] }
            let mode: PaneCloseMode
            switch TabCloseGateDecision.gate(
                simsAffected: affected,
                pinnedSimDecision: pinned,
                multiPane: multiPaneTabCount > 0,
                programsAffected: !programs.isEmpty
            ) {
            case .simDisposition:
                let decision = await CloseDecisions.bulkTabClose(
                    config: config,
                    state: CloseSuppressionState.shared,
                    context: context,
                    count: sessionIDs.count,
                    window: self.view.window,
                    whileTargetLives: { [weak self] in
                        self?.anyTabLives(of: ids) ?? false
                    }
                )
                switch decision {
                case .detach:
                    mode = .detach

                case .shutdown:
                    mode = .shutdown

                case .cancel:
                    return
                }

            case let .programConfirm(gateMode):
                guard await CloseDecisions.bulkProgramTabClose(
                    names: programs,
                    tabCount: sessionIDs.count,
                    window: self.view.window,
                    whileTargetLives: { [weak self] in
                        self?.anyTabLives(of: ids) ?? false
                    }
                ) else { return }
                mode = gateMode

            case let .multiPaneConfirm(gateMode):
                guard await CloseDecisions.bulkMultiPaneTabClose(
                    config: config,
                    state: CloseSuppressionState.shared,
                    context: context,
                    tabCount: sessionIDs.count,
                    multiPaneTabCount: multiPaneTabCount,
                    window: self.view.window,
                    whileTargetLives: { [weak self] in
                        self?.anyTabLives(of: ids) ?? false
                    }
                ) else { return }
                mode = gateMode

            case let .close(gateMode):
                mode = gateMode
            }
            for target in targets {
                self.router.dispatch(.closeTab(self.windowID, target.id, mode: mode))
            }
        }
    }

    /// Whether a bulk close still has anything to close. One prompt
    /// covers the whole batch, so it stays meaningful while any target
    /// survives and only becomes unanswerable once they are all gone.
    private func anyTabLives(of ids: [TabID]) -> Bool {
        ids.contains { tabListVM.tab(id: $0) != nil }
    }

    // MARK: - Right-click menu handlers

    /// Each `…FromMenu` handler resolves the per-tab `representedObject`
    /// (a `TabID`) before dispatching, so the menu always targets the
    /// tab the user right-clicked, not the currently selected one.
    ///
    /// `duplicateSelectedTab` below is the main-menu counterpart, and
    /// deliberately does not: a static menu item carries no represented
    /// object, so it names the selected tab instead.

    @objc
    func toggleProtectionFromMenu(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? TabID,
            let tab = tabListVM.tab(id: tabID) else { return }
        // Toggle relative to what's shown *now* (effective-hidden), so a
        // menu action during an in-flight transition flips the right way.
        let makeProtected = !tab.isEffectivelyProtected
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.router.applyTabProtection(
                tab: tabID,
                isProtected: makeProtected
            )
            // Unlike a CLI caller, the human at the protection menu has no
            // result stream to read: surface a rejection as an alert rather
            // than dropping it silently. The tab stays fail-closed, so a
            // failed "protect" leaves it hidden but unconfirmed; the user
            // needs to know it didn't take.
            if outcome != .committed {
                self.presentProtectionChangeFailure(
                    makeProtected: makeProtected,
                    error: .internalError(
                        outcome == .pending
                            ? "tab protection is still pending"
                            : "tab protection was rejected"
                    )
                )
            }
        }
    }

    private func presentProtectionChangeFailure(makeProtected: Bool, error: IntentError) {
        let alert = NSAlert()
        alert.messageText = makeProtected
            ? "Couldn’t protect this tab"
            : "Couldn’t unprotect this tab"
        alert.informativeText = error.hint
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    @objc
    func duplicateTabFromMenu(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? TabID else { return }
        duplicateTab(id: tabID)
    }

    /// Shell → Duplicate Tab, which duplicates the *selected* tab. Same
    /// represented-object reason as `renameSelectedTab`.
    @objc
    func duplicateSelectedTab(_ sender: Any?) {
        guard let tab = tabListVM.selectedTab else { return }
        duplicateTab(id: tab.id)
    }

    private func duplicateTab(id tabID: TabID) {
        // Inherit the source tab's role and current working directory
        // (the OSC 7 trail the strip already tracks). nil cwd falls
        // back to the GUI's CWD: matches `newTab` behavior when no
        // OSC 7 has landed yet.
        let role = tabListVM.tab(id: tabID)?.role ?? .agent
        let cwd = tabContentByID[tabID]?.latestWorkingDirectory
        switch role {
        case .agent:
            router.dispatch(.newTab(windowID, cwd: cwd))

        case .automation:
            router.dispatch(.openAutomationTab(windowID, cwd: cwd))
        }
    }

    @objc
    func newTabFromMenu(_ sender: NSMenuItem) {
        // Identical to ⌘T / the strip's "+" button. Provided in the
        // context menu so the right-click is a one-stop surface.
        router.dispatch(.newTab(windowID))
    }

    @objc
    func openAutomationTabFromMenu(_ sender: NSMenuItem) {
        router.dispatch(.openAutomationTab(windowID))
    }

    @objc
    func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? TabID else { return }
        requestCloseTab(id: tabID)
    }

    @objc
    func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? TabID else { return }
        let others = tabListVM.tabs.map(\.id).filter { $0 != tabID }
        requestBulkCloseTabs(ids: others)
    }

    @objc
    func closeTabsToRightFromMenu(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? TabID else { return }
        let ids = tabListVM.tabs.map(\.id)
        guard let pivot = ids.firstIndex(of: tabID) else { return }
        let trailing = Array(ids[(pivot + 1)...])
        requestBulkCloseTabs(ids: trailing)
    }

    // MARK: - Reconcile (observe { render() })

    /// Reflect TabListViewModel into the strip + content. Reads all
    /// observed fields each pass (the observe() tracking contract): the
    /// tabs array (structure), selectedIndex, each tab's displayTitle
    /// (so OSC/CWD/rename updates redraw the label), and the selected tab's
    /// proxyIconPath (so a `cd` re-points the titlebar folder even when a
    /// higher-precedence label source keeps displayTitle unchanged).
    private func render() {
        let tabs = tabListVM.tabs
        let liveIDs = Set(tabs.map(\.id))

        // Drop VCs for removed tabs (Router already closed their daemon
        // sessions); the VC's teardown handles AppKit/libghostty cleanup.
        for id in Array(tabContentByID.keys) where !liveIDs.contains(id) {
            if let removed = tabContentByID.removeValue(forKey: id) {
                removed.teardown()
                removed.removeFromParent()
                if removed.isViewLoaded { removed.view.removeFromSuperview() }
            }
        }
        for id in Array(failedTabContentByID.keys) where !liveIDs.contains(id) {
            guard let removed = failedTabContentByID.removeValue(forKey: id) else { continue }
            removed.removeFromParent()
            if removed.isViewLoaded { removed.view.removeFromSuperview() }
        }
        // Create VCs for new tabs. Failures show an alert; the Router has
        // already minted the daemon session, so a provisioning failure
        // here strands it until the user closes the tab.
        for tab in tabs where tabContentByID[tab.id] == nil {
            if tab.lifecycle == .failed {
                if failedTabContentByID[tab.id] == nil {
                    let failed = makeFailedTabContent(
                        message: tab.failureMessage ?? "The terminal session could not be created."
                    )
                    addChild(failed)
                    failedTabContentByID[tab.id] = failed
                }
                continue
            }
            if let failed = failedTabContentByID.removeValue(forKey: tab.id) {
                failed.removeFromParent()
            }
            do {
                let tabContent = try TabContentViewController(
                    tabID: tab.id,
                    windowID: windowID,
                    primary: tab.primaryTerminal,
                    sessionName: tab.primaryTerminal.name,
                    role: tab.role,
                    tabListVM: tabListVM,
                    daemonClient: daemonClient,
                    paneResurrect: paneResurrect,
                    router: router
                )
                wireTerminalExit(of: tabContent)
                addChild(tabContent)
                tabContentByID[tab.id] = tabContent
            } catch {
                presentInitFailure(error)
            }
        }

        // Last tab closed → close the window (AppKit will dispatch the
        // closeWindow route via windowWillClose).
        if tabs.isEmpty {
            view.window?.performClose(nil)
            return
        }

        let currentIDs = tabs.map(\.id)
        if currentIDs != lastTabIDs {
            rebuildStrip(for: tabs)
            lastTabIDs = currentIDs
        } else {
            updateStripLabels(for: tabs)
        }
        applySelection(for: tabs)
    }

    /// Install the per-terminal close handlers on `tabContent`.
    ///
    /// `onTerminalExit` (the shell died on its own): when the closing
    /// terminal is the last one in the tab, close the whole tab
    /// silently, preserving the "last-shell-exits-closes-tab"
    /// behavior. A shell exit is not an explicit close gesture, so no
    /// prompt applies even when other panes go down with the tab.
    /// When N > 1, close only that terminal pane.
    ///
    /// `onTerminalCloseRequested` (the user's explicit Close Pane):
    /// same pane-vs-tab arithmetic, but the last-terminal case routes
    /// through `requestCloseTab` so the tab-close prompt policy
    /// applies. An explicit close of the tab's last terminal is a tab
    /// close, not a shell death.
    ///
    /// Title / CWD wiring for each terminal lives inside the content
    /// VC's reconciler because it must run per-terminal at creation
    /// time.
    private func wireTerminalExit(of tabContent: TabContentViewController) {
        let tabListVM = self.tabListVM
        let router = self.router
        let windowID = self.windowID
        let tabID = tabContent.tabID
        tabContent.onTerminalExit = { terminalID in
            let tab = tabListVM.tab(id: tabID)
            if let tab, tab.terminals.count > 1 {
                router.dispatch(
                    .closeTerminalPane(
                    tab: tabID,
                    terminal: terminalID,
                    mode: .detach
                )
                    )
                return
            }
            // Last terminal in this tab: close the whole tab explicitly.
            router.dispatch(.closeTab(windowID, tabID, mode: .detach))
        }
        tabContent.onTerminalCloseRequested = { [weak self] terminalID in
            guard let self else { return }
            let tab = tabListVM.tab(id: tabID)
            if let tab, tab.terminals.count > 1 {
                router.dispatch(
                    .closeTerminalPane(
                    tab: tabID,
                    terminal: terminalID,
                    mode: .detach
                )
                    )
                return
            }
            self.requestCloseTab(id: tabID)
        }
    }

    private func rebuildStrip(for tabs: [TabState]) {
        // Tear down previous cells in the container (independent of the
        // outer strip, which holds [cellsContainer, addButton]).
        for cell in cellsContainer.arrangedSubviews {
            cellsContainer.removeArrangedSubview(cell)
            cell.removeFromSuperview()
        }
        // Width policy:
        //   1 tab  → solo cap 480, strip narrow (trailing empty)
        //   N ≥ 2  → strip spans full width, cellsContainer divides
        //            equally via .fillEqually
        // Every horizontal floor a pill carries is a floor on the window,
        // since this strip is the window's content root, so they all sit
        // below the window-drag threshold. `TabPillLayout` holds the band
        // and the order they yield in.
        if TabWidthFreezeDecision.shouldThawOnTabCountChange(
            from: lastTabIDs.count,
            to: tabs.count
        ) {
            thawCellWidths()
        }
        // Held still while frozen; `thawCellWidths` applies it on release.
        if frozenCellWidth == nil {
            applyStripWidthPolicy(tabCount: tabs.count)
        }
        for (idx, tab) in tabs.enumerated() {
            let title = TabTitleButton(
                title: displayTitle(for: tab),
                target: self,
                action: #selector(selectTabFromButton(_:))
            )
            title.tag = tab.id.value
            // Drag source: the payload provider looks up the tab's live
            // index at drag start (robust to any reorder since the cell
            // was built), and tear-off relocates the tab into a new
            // window at the drop point.
            title.makeDragPayload = { [weak self] in
                guard let self,
                    let index = self.tabListVM.tabs.firstIndex(where: { $0.id == tab.id })
                else { return nil }
                return TabDragPayload(
                    sourceWindowID: self.windowID,
                    tabID: tab.id,
                    sourceIndex: index
                )
            }
            title.onTearOff = { [weak self] screenPoint in
                guard let self else { return }
                self.tabTransfer?.tearOffTab(tab.id, from: self.windowID, at: screenPoint)
            }
            // Settle any live reorder if the drag ends without a
            // destination callback (Escape / cancel).
            title.onDragEnded = { [weak self] in self?.endLiveReorder(commit: false) }
            title.setButtonType(.pushOnPushOff)
            // No system bezel: the cell view itself paints a muted
            // background for the selected tab (see `applySelection`),
            // an understated pill look rather than AppKit's bold
            // accent-tinted `.recessed` style.
            title.isBordered = false
            title.bezelStyle = .texturedRounded
            // Let the title stretch so the cell can fill its slot in
            // the cellsContainer.
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            // Truncation is a drawing behavior and leaves the button
            // asking for its full width, so the title only actually
            // gives way once its compression resistance is lowered too.
            // It yields first, being the part that degrades into
            // something still worth reading.
            title.setContentCompressionResistancePriority(
                TabPillLayout.titleCompression,
                for: .horizontal
            )
            // Single-line, tail-truncate at narrow widths so a long
            // title never pushes the close button past the cell's
            // trailing edge.
            title.lineBreakMode = .byTruncatingTail
            title.cell?.usesSingleLineMode = true

            // Right-click context menu. Items target the responder
            // chain (nil target) so the strip VC's @objc handlers
            // fire when the menu opens; each item carries the TabID
            // via `representedObject` so the handler knows which tab
            // it was clicked on.
            title.menu = makeTabStripContextMenu(
                for: tab.id,
                isEffectivelyProtected: tab.isEffectivelyProtected,
                isOnlyTab: tabs.count == 1,
                isLastTab: idx == tabs.count - 1,
                target: self
            )

            let close = NSButton(
                title: "✕",
                target: self,
                action: #selector(closeTabFromButton(_:))
            )
            close.tag = tab.id.value
            // No system bezel: the cell's pill paints around the
            // button so the close mark just floats inside it.
            close.isBordered = false
            close.bezelStyle = .texturedRounded
            close.setButtonType(.momentaryPushIn)
            close.toolTip = "Close Tab"
            close.setContentHuggingPriority(.required, for: .horizontal)
            // Last thing in the pill to give, so a crowded strip stays
            // clickable, but still below the window-drag threshold.
            close.setContentCompressionResistancePriority(
                TabPillLayout.closeButtonCompression,
                for: .horizontal
            )
            Self.applyAccessibilityIdentifiers(
                pill: title, close: close, shortId: Self.accessibilityShortID(for: tab)
            )
            // Reserve space always but fade alpha 0 → 1 on hover so
            // entering the cell doesn't reflow the layout.

            let cell = TabPillCell(frame: .zero)
            cell.install(close: close, title: title)
            applyMarkers(to: cell, tab: tab)
            cell.setShortcut(
                TabShortcutDecision.action(atIndex: idx, tabCount: tabs.count)
            )
            cell.onHoverChange = { [weak self] in self?.applySeparators() }
            // The whole pill is the drag image.
            title.snapshotSource = cell
            cell.translatesAutoresizingMaskIntoConstraints = false
            // Pin the pill height: the strip is 34pt and the cell
            // centers at 28pt with .centerY alignment on the cells
            // container, giving 3pt margin top/bottom. The track is
            // pinned to the same 28pt extent below.
            cell.heightAnchor.constraint(equalToConstant: 28).isActive = true
            // A preference, not a floor: `.fillEqually` under a required
            // stripFillTrailing already determines the width from the
            // window, so this only decides what a cell asks for. It sits
            // above the pill's content priorities, so a cell with room
            // widens before its ✕ is squashed, and below the window-drag
            // threshold, so wanting 180 never pins the window.
            let minWidth = cell.widthAnchor.constraint(
                greaterThanOrEqualToConstant: TabPillLayout.cellMinimumWidth
            )
            minWidth.priority = TabPillLayout.cellMinimumWidthPriority
            minWidth.isActive = true
            cellsContainer.insertArrangedSubview(cell, at: idx)
        }
        applyFrozenCellWidths()
    }

    /// Push the selected tab's label and directory onto the window. Called from
    /// every render pass and again from `viewDidAppear`, since the first pass
    /// runs before the strip has a window and both writes silently no-op there.
    private func applyWindowMetadata(for tabContent: TabContentViewController) {
        view.window?.title = tabContent.displayTitle
        // The proxy icon is a control, not a caption: it is dragged into Finder
        // and right-clicked for the ancestor-path menu, so it has to resolve to
        // the tab on screen rather than whichever terminal last emitted OSC 7.
        // Empty string clears it, leaving no folder for a tab with no known
        // directory instead of the last one set.
        view.window?.representedFilename = tabContent.proxyIconPath ?? ""
    }

    private func displayTitle(for tab: TabState) -> String {
        tabContentByID[tab.id]?.displayTitle
            ?? tab.name
            ?? (tab.lifecycle == .failed ? "Tab creation failed" : "shell")
    }

    private func makeFailedTabContent(message: String) -> NSViewController {
        let controller = NSViewController()
        let root = NSView()
        let title = NSTextField(labelWithString: "Terminal session could not be created")
        title.font = .preferredFont(forTextStyle: .title2)
        let detail = NSTextField(wrappingLabelWithString: message)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -40)
        ])
        controller.view = root
        return controller
    }

    @objc
    private func frameDemandChanged(_ notification: Notification) {
        reconcileFrameDemand()
    }

    private func reconcileFrameDemand() {
        let visible = SimulatorFrameDemandDecision.isWindowEligible(
            visible: view.window?.isVisible ?? false,
            minimized: view.window?.isMiniaturized ?? false,
            applicationHidden: NSApp.isHidden
        )
        for (id, tab) in tabContentByID {
            tab.setSimulatorFrameDemand(visible && id == tabListVM.selectedTab?.id)
        }
    }

    private func applySelection(for tabs: [TabState]) {
        reconcileFrameDemand()
        guard let index = tabListVM.selectedIndex,
            tabs.indices.contains(index) else { return }
        let selected = tabs[index]
        let selectedID = selected.id
        guard let selectedContent = tabContentByID[selectedID]
            ?? failedTabContentByID[selectedID] else { return }
        let selectionChanged = (lastSelectedID != selectedID)

        // Selected-state styling: flip the cell's `isSelected` flag,
        // which repaints its white-alpha background layer. Looking up by
        // TabID (button tag) rather than array position is robust to a
        // rebuildStrip pass that skipped a tab whose `tabContentByID`
        // entry hadn't landed yet.
        for tab in tabs {
            guard let cell = cell(forTab: tab.id),
                let button = cell.titleButton else {
                continue
            }
            let isSelected = (tab.id == selectedID)
            button.state = isSelected ? .on : .off
            cell.isSelected = isSelected
            Self.applyTitleStyling(
                to: button,
                text: displayTitle(for: tab),
                isSelected: isSelected
            )
        }
        applySeparators()
        if let tabContent = selectedContent as? TabContentViewController {
            applyWindowMetadata(for: tabContent)
        } else {
            view.window?.title = displayTitle(for: selected)
            view.window?.representedFilename = ""
        }

        // Only swap the content view and refocus on a *real* selection
        // change: a title/CWD-driven re-render must not steal first
        // responder from a sim pane the user focused.
        if selectionChanged {
            content.subviews.forEach { $0.removeFromSuperview() }
            selectedContent.view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(selectedContent.view)
            NSLayoutConstraint.activate(
                [
                selectedContent.view.topAnchor.constraint(equalTo: content.topAnchor),
                selectedContent.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                selectedContent.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                selectedContent.view.trailingAnchor.constraint(equalTo: content.trailingAnchor)
                ]
                )
            (selectedContent as? TabContentViewController)?.restoreRememberedFocus()
            lastSelectedID = selectedID
        }
    }

    /// Find the tab pill for `tabID` via the tag stamped on its title
    /// button. Keying by TabID instead of array position keeps
    /// `applySelection`/`updateStripLabels` correct if `rebuildStrip`
    /// ever skips a tab whose content is still being provisioned.
    private func cell(forTab tabID: TabID) -> TabPillCell? {
        for case let pill as TabPillCell in cellsContainer.arrangedSubviews
        where pill.titleButton?.tag == tabID.value {
            return pill
        }
        return nil
    }

    /// Paint a boundary only when both neighboring cells are inactive
    /// and unhovered. Reading the arranged subviews keeps the rule correct
    /// during live drag reordering, before the navigation model commits.
    private func applySeparators() {
        let cells = cellsContainer.arrangedSubviews.compactMap { $0 as? TabPillCell }
        let visibility = TabSeparatorDecision.trailingVisibility(
            for: cells.map { (isSelected: $0.isSelected, isHovered: $0.isHovered) }
        )
        for (cell, isVisible) in zip(cells, visibility) {
            cell.showsTrailingSeparator = isVisible
        }
    }

    /// Drive a pill's markers from the tab's current state.
    ///
    /// Called from the rebuild AND from the same-tabs path, because protection
    /// flips while the tab-ID list is unchanged and only the same-tabs path
    /// sees that. Automation rides the same call so marker selection has one
    /// home rather than two; a tab's role is a `let`, so the entry it
    /// contributes is stable and `setMarkers` skips the remount.
    private func applyMarkers(to cell: TabPillCell, tab: TabState) {
        cell.setMarkers(
            TabMarkerDecision.markers(
                role: tab.role,
                isEffectivelyProtected: tab.isEffectivelyProtected
            )
        )
    }

    private func updateStripLabels(for tabs: [TabState]) {
        for (idx, tab) in tabs.enumerated() {
            // Look up by TabID rather than array index: same reasoning
            // as `applySelection`'s TabID-keyed loop.
            guard let cell = cell(forTab: tab.id),
                let button = cell.titleButton else { continue }
            Self.applyTitleStyling(
                to: button,
                text: displayTitle(for: tab),
                isSelected: cell.isSelected
            )
            applyMarkers(to: cell, tab: tab)
            cell.setShortcut(
                TabShortcutDecision.action(atIndex: idx, tabCount: tabs.count)
            )
            Self.applyAccessibilityIdentifiers(
                pill: button, close: cell.closeButton, shortId: Self.accessibilityShortID(for: tab)
            )
            // Rebuild the per-tab context menu so protection toggle title
            // ("Protect Tab" ↔ "Unprotect Tab"), check state, and the
            // enable bits for Close Others / Close to the Right
            // reflect the current TabState. `rebuildStrip` only fires
            // when the tab-ID list changes; same-tabs-different-state
            // paths (protection toggle, position-driven last-tab flip)
            // land here.
            button.menu = makeTabStripContextMenu(
                for: tab.id,
                isEffectivelyProtected: tab.isEffectivelyProtected,
                isOnlyTab: tabs.count == 1,
                isLastTab: idx == tabs.count - 1,
                target: self
            )
        }
    }

    private func presentInitFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not open a new tab"
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Tab drag: reorder / move / detach (one gesture)
    //
    // Dragging a tab is a single interaction, and where the cursor ends up
    // decides the outcome: no modes, no insertion caret. Within this
    // strip the pills reorder live (a pill slides aside as soon as the
    // cursor crosses a third of the way into it, well before its far
    // edge). Over another window's strip the live tab moves there; on
    // empty space it tears off into a new window (the drag source handles
    // that on release). The cells container forwards its NSView drag
    // callbacks here.

    func stripDraggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Live reorder moves pills between slots, so held widths stop matching
        // the strip they were measured against.
        thawCellWidths()
        return stripDraggingUpdated(sender)
    }

    func stripDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let payload = decodeTabPayload(sender), acceptsDrop(from: payload) else {
            endLiveReorder(commit: false)
            return []
        }
        // Same-window: slide the pills live. Cross-window: no in-strip
        // feedback. The tab lands on drop; the gesture is identical, only
        // the destination differs.
        if payload.sourceWindowID == windowID {
            liveShiftDraggedPill(payload.tabID, for: sender)
        }
        return .move
    }

    func stripDraggingExited(_ sender: (any NSDraggingInfo)?) {
        // Cursor left the strip mid-drag (heading to another window or
        // empty space): snap the pills back to the model order; the
        // move / detach commits on release.
        endLiveReorder(commit: false)
    }

    func stripPerformDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let payload = decodeTabPayload(sender), acceptsDrop(from: payload) else {
            endLiveReorder(commit: false)
            return false
        }
        if payload.sourceWindowID == windowID {
            // Commit the live-shifted arrangement to the nav model.
            endLiveReorder(commit: true)
            return true
        }
        // Cross-window move: relocate the live tab into this strip at the
        // slot the cursor is over.
        guard let transfer = tabTransfer else { return false }
        transfer.moveTab(
            payload.tabID,
            from: payload.sourceWindowID,
            to: windowID,
            atIndex: insertionSlot(for: sender)
        )
        return true
    }

    /// A drag is droppable here when it's this window's own reorder, or a
    /// cross-window move and we have a transfer coordinator to perform it.
    private func acceptsDrop(from payload: TabDragPayload) -> Bool {
        payload.sourceWindowID == windowID || tabTransfer != nil
    }

    private func decodeTabPayload(_ sender: any NSDraggingInfo) -> TabDragPayload? {
        guard let items = sender.draggingPasteboard.pasteboardItems else { return nil }
        let pbType = NSPasteboard.PasteboardType(TabDragPayload.pasteboardType)
        for item in items {
            guard let data = item.data(forType: pbType) else { continue }
            if let payload = try? JSONDecoder().decode(TabDragPayload.self, from: data) {
                return payload
            }
        }
        return nil
    }

    /// Slide the dragged pill to the slot the cursor is over. Purely
    /// visual: the arranged order of `cellsContainer` changes but the nav
    /// model doesn't until the drop commits, so a cancel just restores the
    /// order and no mid-drag `render()` can tear down the in-flight drag
    /// source pill.
    private func liveShiftDraggedPill(_ tabID: TabID, for sender: any NSDraggingInfo) {
        guard let draggedCell = cell(forTab: tabID) else { return }
        liveReorderTabID = tabID
        draggedCell.alphaValue = Self.draggedPillAlpha
        let cells = cellsContainer.arrangedSubviews
        guard let current = cells.firstIndex(of: draggedCell) else { return }
        let cursorX = cellsContainer.convert(sender.draggingLocation, from: nil).x
        let frames = cells.map { cellsContainer.convert($0.bounds, from: $0) }
        let target = TabDropMath.liveTargetIndex(
            draggedIndex: current,
            cursorX: cursorX,
            cellFrames: frames
        )
        guard target != current else { return }
        cellsContainer.removeArrangedSubview(draggedCell)
        cellsContainer.insertArrangedSubview(draggedCell, at: target)
        applySeparators()
    }

    /// Finish a live reorder. `commit` dispatches the reorder to the nav
    /// model at the dragged pill's final visual slot; otherwise the
    /// arrangement snaps back to the model. Either way the pill's alpha is
    /// restored. No-op when no live reorder is in progress (safe to call
    /// from every drag-end path).
    func endLiveReorder(commit: Bool) {
        guard let tabID = liveReorderTabID else { return }
        liveReorderTabID = nil
        if commit,
            let draggedCell = cell(forTab: tabID),
            let finalIndex = cellsContainer.arrangedSubviews.firstIndex(of: draggedCell) {
            draggedCell.alphaValue = 1
            router.dispatch(.reorderTab(windowID, tabID, toIndex: finalIndex))
            return
        }
        restoreStripOrder()
    }

    /// Re-arrange the pills to match the nav model's order and reset their
    /// alpha: undoes a live reorder that didn't commit. Only touches
    /// arrangement (never removes cells from the view hierarchy), so an
    /// active drag session's source pill stays alive.
    private func restoreStripOrder() {
        var cellByTag: [Int: TabPillCell] = [:]
        for case let cell as TabPillCell in cellsContainer.arrangedSubviews {
            cell.alphaValue = 1
            if let tag = cell.titleButton?.tag { cellByTag[tag] = cell }
        }
        for cell in cellsContainer.arrangedSubviews {
            cellsContainer.removeArrangedSubview(cell)
        }
        for tab in tabListVM.tabs {
            if let cell = cellByTag[tab.id.value] {
                cellsContainer.addArrangedSubview(cell)
            }
        }
        applySeparators()
    }

    /// Insertion slot for a cross-window drop: the gap index the cursor
    /// is over among this strip's pills (which don't include the dragged
    /// tab).
    private func insertionSlot(for sender: any NSDraggingInfo) -> Int {
        let cursorX = cellsContainer.convert(sender.draggingLocation, from: nil).x
        let midXs = cellsContainer.arrangedSubviews.map {
            cellsContainer.convert($0.bounds, from: $0).midX
        }
        return TabDropMath.insertionIndex(forX: cursorX, cellMidXs: midXs)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension TabStripViewController {
    /// NSStackView subclass that reports its empty regions as draggable, so
    /// click-and-drag on the strip background moves the window (the same
    /// machinery the standard title bar uses). NSButton subviews (the tab
    /// pills, "✕" close, and "+" add) consume their own clicks via the
    /// normal responder chain; only mouse-downs that miss every button reach
    /// this view, where `mouseDownCanMoveWindow` lets AppKit take over.
    final class DraggableStackView: NSStackView {
        /// When set (the cells container), tab-drag callbacks forward to the
        /// strip VC so it (not the view) owns the reorder/relocate logic.
        /// The outer strip leaves this nil and never registers dragged types,
        /// so only the cells lane accepts drops.
        weak var dropDelegate: TabStripViewController?
        /// Called when the pointer leaves this stack, for the strip that wants
        /// to know a run of ✕ closes is over. Left nil elsewhere, which also
        /// keeps the tracking area off every stack that does not need one.
        var onPointerExit: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard onPointerExit != nil else { return }
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
            )
        }

        override func mouseExited(with event: NSEvent) {
            onPointerExit?()
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            dropDelegate?.stripDraggingEntered(sender) ?? []
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            dropDelegate?.stripDraggingUpdated(sender) ?? []
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            dropDelegate?.stripDraggingExited(sender)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            dropDelegate?.stripPerformDragOperation(sender) ?? false
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }
    }

    /// A tab pill's title button that doubles as the drag source for tab
    /// reorder. NSButton's cell runs a modal tracking loop on mouseDown that
    /// swallows drag detection, so (like the in-file `NewTabButton`) this
    /// overrides `mouseDown` with a manual event loop: a plain click sends
    /// the select action; a drag past the threshold begins a tab drag
    /// session. The ✕ close button and right-click menu are untouched (they
    /// own their own hits).
    final class TabTitleButton: NSButton, NSDraggingSource {
        /// Builds the pasteboard payload at drag start (looks up the tab's
        /// live index). Returns nil to abort the drag.
        var makeDragPayload: (() -> TabDragPayload?)?
        /// View whose snapshot becomes the drag image: the whole pill.
        weak var snapshotSource: NSView?
        /// Invoked when the drag ends with no destination consuming it (a
        /// drop on empty space): the tear-off hook. Receives the screen point.
        var onTearOff: ((NSPoint) -> Void)?
        /// Fires on every drag end (drop, cancel, or tear-off) so the strip
        /// can settle any in-progress live reorder even when no destination
        /// callback ran (e.g. the user pressed Escape).
        var onDragEnded: (() -> Void)?

        private var mouseDownPoint: CGPoint?

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            var tracking = true
            var didDrag = false
            while tracking {
                guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else {
                    break
                }
                switch next.type {
                case .leftMouseDragged:
                    guard let start = mouseDownPoint else { break }
                    let current = convert(next.locationInWindow, from: nil)
                    if hypot(current.x - start.x, current.y - start.y) >= 4 {
                        didDrag = true
                        tracking = false
                        beginTabDrag(with: next)
                    }

                case .leftMouseUp:
                    tracking = false
                    if !didDrag, isWithinPill(next), let action {
                        _ = sendAction(action, to: target)
                    }

                default:
                    break
                }
            }
            mouseDownPoint = nil
        }

        /// Whether `event` ended over this tab's pill rather than only over
        /// the button itself.
        ///
        /// The shortcut badge is a sibling inside the pill that routes its
        /// hits here, so a release over it arrives with a location outside
        /// this button's own bounds. Testing the pill keeps that a click on
        /// the tab. `snapshotSource` is the pill (it is what the drag image
        /// snapshots), and falls back to self before the strip wires it.
        private func isWithinPill(_ event: NSEvent) -> Bool {
            let pill = snapshotSource ?? self
            return pill.bounds.contains(pill.convert(event.locationInWindow, from: nil))
        }

        private func beginTabDrag(with event: NSEvent) {
            guard let payload = makeDragPayload?(),
                let data = try? JSONEncoder().encode(payload) else { return }
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(TabDragPayload.pasteboardType))
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let snapshot = renderSnapshot()
            draggingItem.setDraggingFrame(
                CGRect(origin: convert(event.locationInWindow, from: nil), size: snapshot.size),
                contents: snapshot
            )
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        private func renderSnapshot() -> NSImage {
            let source = snapshotSource ?? self
            guard let rep = source.bitmapImageRepForCachingDisplay(in: source.bounds) else {
                return NSImage(size: NSSize(width: 1, height: 1))
            }
            source.cacheDisplay(in: source.bounds, to: rep)
            let image = NSImage(size: source.bounds.size)
            image.addRepresentation(rep)
            return image
        }

        // MARK: - NSDraggingSource

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            // No destination consumed the drop → tear the tab off into a new
            // window at the drop point.
            if operation.isEmpty {
                onTearOff?(screenPoint)
            }
            // Always let the strip settle a live reorder (idempotent, a
            // no-op after a committed drop / restored exit).
            onDragEnded?()
        }
    }

    /// Root view of the strip controller. Reports draggable so the empty
    /// integrated-title-bar region (the band to the right of a single tab's
    /// strip, where the strip is at its intrinsic ~520pt and the rest of
    /// the window width sits beneath the title bar) still drags the window.
    /// Also fires `onEffectiveAppearanceChange` so the strip VC can repaint
    /// the selected pill's CGColor snapshot on a light/dark flip. The
    /// override lives here because `viewDidChangeEffectiveAppearance` is an
    /// `NSResponder`/`NSView` method, not an `NSViewController` one.
    final class DraggableRootView: NSView {
        var onEffectiveAppearanceChange: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { true }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            onEffectiveAppearanceChange?()
        }
    }

    /// One custom tab cell that:
    ///
    ///   - paints its background via explicit white-alpha tints over the
    ///     window's ghostty bg color (5% track → 10% hover → 16% selected),
    ///     giving clean, predictable contrast that NSVisualEffectView
    ///     materials would warm with dark-mode tints
    ///   - lays out `[✕, marker…, title]` as a horizontal NSStackView, with
    ///     the close ✕ leftmost and the title filling the rest of the width
    ///   - reserves space for the close button always (alpha-fades it on
    ///     hover rather than `isHidden`-toggling) so the layout doesn't
    ///     jitter when the cursor enters
    ///
    /// Selection comes from the strip controller; the cell tracks hover and
    /// paints both states.
    final class TabPillCell: NSView {
        weak var closeButton: NSButton?
        var isSelected: Bool = false {
            didSet { refreshMaterial() }
        }
        private(set) var isHovered = false {
            didSet {
                refreshMaterial()
                onHoverChange?()
            }
        }
        var onHoverChange: (() -> Void)?
        var showsTrailingSeparator = false {
            didSet { trailingSeparator.isHidden = !showsTrailingSeparator }
        }

        /// The pill's title button, stored explicitly because the shortcut
        /// badge follows it in the stack. Every TabID-keyed lookup in the strip
        /// reads this button's tag.
        private(set) weak var titleButton: NSButton?

        private let background = NSView()
        private let stack = NSStackView()
        private let trailingSeparator = TabSeparatorView()
        /// The markers currently mounted, in stack order, so `setMarkers` can
        /// return early on an unchanged list. The same-tabs render path calls it
        /// on every pass, and OSC title updates make those continuous.
        private var installedMarkers: [TabPillMarker] = []
        private var markerViews: [NSView] = []
        /// The chord the badge currently renders, so `setShortcut` can return
        /// early when nothing moved. Holds the rendered text rather than the
        /// action, because that is what the comparison is actually about.
        private var installedShortcut: String?
        private var shortcutLabel: TabShortcutLabel?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            // Matches the tab track's radius, so track + cell are the same
            // pill shape, just different alpha.
            layer?.cornerRadius = 14
            layer?.cornerCurve = .continuous
            // The background owns the capsule clipping. Leaving the cell itself
            // unclipped lets its trailing separator render at full height instead
            // of being reduced to a tiny chord by the rounded trailing edge.
            layer?.masksToBounds = false

            background.translatesAutoresizingMaskIntoConstraints = false
            background.wantsLayer = true
            background.layer?.cornerRadius = 14
            background.layer?.cornerCurve = .continuous
            background.layer?.masksToBounds = true
            background.layer?.backgroundColor = NSColor.clear.cgColor
            addSubview(background)

            stack.orientation = .horizontal
            stack.spacing = 4
            stack.alignment = .centerY
            stack.distribution = .fill
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)

            trailingSeparator.translatesAutoresizingMaskIntoConstraints = false
            trailingSeparator.isHidden = true
            trailingSeparator.setAccessibilityElement(false)
            addSubview(trailingSeparator)

            // NSStackView emits its edge insets and inter-view spacing at
            // `.required`, so pinning the stack's trailing edge outright
            // would floor every pill at a width nothing below `.required`
            // could relieve, multiplied by the tab count. Letting this one
            // break instead means a badly crowded pill overruns its own
            // trailing edge by a few points, which beats pinning the window.
            // The leading pin stays required so the stack is unambiguous.
            let stackTrailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
            stackTrailing.priority = TabPillLayout.stackTrailingPin

            NSLayoutConstraint.activate([
                background.topAnchor.constraint(equalTo: topAnchor),
                background.bottomAnchor.constraint(equalTo: bottomAnchor),
                background.leadingAnchor.constraint(equalTo: leadingAnchor),
                background.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stackTrailing,
                trailingSeparator.centerYAnchor.constraint(equalTo: centerYAnchor),
                trailingSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
                trailingSeparator.widthAnchor.constraint(equalToConstant: 1),
                trailingSeparator.heightAnchor.constraint(equalToConstant: 20)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

        /// The image view for one marker.
        ///
        /// Solid glyphs stay legible at this size. Teal and orange separate the
        /// two markers independently of the user's accent color, which a
        /// low-chroma choice such as Graphite can otherwise flatten into the
        /// pill. Yellow is the obvious bolt and blurs into the orange lock.
        ///
        /// Neither carries an accessibility *identifier*. Consumers collect the
        /// strip's named controls by the `deviceterm.tab.` prefix and count the
        /// result as pills, so publishing one here would inflate that count. The
        /// image carries a description instead, which names the marker without
        /// putting it in that set.
        private static func markerView(for marker: TabPillMarker) -> NSImageView {
            let symbolName: String
            let describedAs: String
            let hoverText: String
            let tint: NSColor
            switch marker {
            case .automation:
                symbolName = "bolt.fill"
                describedAs = "Automation tab"
                hoverText = "Automation tab: can control other tabs and send input to their terminals"
                tint = .systemTeal

            case .protection:
                symbolName = "lock.fill"
                describedAs = "Protected tab"
                hoverText = "Protected tab: hidden from other sessions and closed to automation"
                tint = .systemOrange
            }
            let view = NSImageView()
            view.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: describedAs
            )
            view.contentTintColor = tint
            view.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 13,
                weight: .semibold
            )
            view.imageScaling = .scaleNone
            view.setContentHuggingPriority(.required, for: .horizontal)
            // Outlasts the badge, signalling automation role and protected
            // state the title does not carry, and yields ahead of the ✕.
            view.setContentCompressionResistancePriority(
                TabPillLayout.markerCompression,
                for: .horizontal
            )
            view.toolTip = hoverText
            return view
        }

        /// The badge label. The title truncates ahead of it, but the badge is
        /// the next thing the pill sheds, and `layout()` hides it outright
        /// before it would render as a clipped fragment of the chord. Its
        /// chord stays discoverable in the Window menu.
        ///
        /// Publishes no accessibility identifier, for the same reason the
        /// markers do not: consumers count pills by filtering the
        /// `deviceterm.tab.` prefix, and another named control would inflate
        /// that count.
        private static func makeShortcutLabel() -> TabShortcutLabel {
            let label = TabShortcutLabel(labelWithString: "")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.setContentCompressionResistancePriority(
                TabPillLayout.shortcutBadgeCompression,
                for: .horizontal
            )
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setAccessibilityElement(false)
            return label
        }

        /// Mount the pill's fixed subviews: the close ✕ leftmost so it has a
        /// stable position, the title filling the rest. Markers go on afterwards
        /// through `setMarkers`, which inserts them between the two, and the
        /// shortcut badge through `setShortcut`, which appends after the title.
        func install(close: NSButton, title: NSButton) {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            installedMarkers = []
            markerViews = []
            installedShortcut = nil
            shortcutLabel = nil
            closeButton = close
            titleButton = title
            close.alphaValue = 0
            stack.addArrangedSubview(close)
            stack.addArrangedSubview(title)
        }

        /// Reconcile the pill's markers against `markers`, in that order, between
        /// the close ✕ and the title. Idempotent, so the caller can hand it the
        /// tab's current state on every render pass. Runs after `install`, which
        /// is what puts the two anchors it inserts between into the stack.
        func setMarkers(_ markers: [TabPillMarker]) {
            guard markers != installedMarkers else { return }
            for view in markerViews {
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            markerViews = markers.map { Self.markerView(for: $0) }
            for (offset, view) in markerViews.enumerated() {
                stack.insertArrangedSubview(view, at: 1 + offset)
            }
            installedMarkers = markers
        }

        /// Reconcile the trailing shortcut badge against `action`, nil for a
        /// tab whose position carries no chord. Idempotent like `setMarkers`,
        /// since the same-tabs render path calls it on every pass.
        ///
        /// Appended after the title, so it is the pill's trailing element and
        /// the title is what yields when the cell runs out of width.
        func setShortcut(_ action: KeybindingAction?) {
            let text = action.flatMap { KeybindingCatalog.entry(for: $0)?.chord.displayString }
            guard text != installedShortcut else { return }
            installedShortcut = text
            guard let text else {
                if let label = shortcutLabel {
                    stack.removeArrangedSubview(label)
                    label.removeFromSuperview()
                }
                shortcutLabel = nil
                return
            }
            if shortcutLabel == nil {
                let label = Self.makeShortcutLabel()
                label.pointerTarget = titleButton
                shortcutLabel = label
                stack.addArrangedSubview(label)
            }
            shortcutLabel?.stringValue = text
            refreshShortcutColor()
        }

        /// Follow the title's selected / unselected pair, so the badge dims
        /// with the tab it belongs to rather than staying bright on an
        /// inactive pill.
        private func refreshShortcutColor() {
            shortcutLabel?.textColor = TabStripViewController.titleColor(isSelected: isSelected)
        }

        /// Drop the badge on a pill too narrow to render the chord whole.
        ///
        /// Compression alone would leave a clipped fragment on screen, which
        /// reads as damage rather than as the pill running out of room.
        /// Hiding an arranged subview takes it out of the stack's layout
        /// entirely, so the title gets that space back. No feedback loop: the
        /// cell's width comes from the strip above it, never from what the
        /// pill is showing.
        ///
        /// Written only on a change, because hiding an arranged subview
        /// invalidates the stack's layout: assigning unconditionally here
        /// would dirty the pill on every pass.
        override func layout() {
            super.layout()
            let hidesShortcut = bounds.width < TabPillLayout.shortcutVisibilityWidth
            if let label = shortcutLabel, label.isHidden != hidesShortcut {
                label.isHidden = hidesShortcut
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override func mouseEntered(with event: NSEvent) {
            isHovered = true
            closeButton?.alphaValue = 1
        }

        override func mouseExited(with event: NSEvent) {
            isHovered = false
            closeButton?.alphaValue = 0
        }

        /// Three-level white-alpha contrast over the window's ghostty
        /// background tint, preserving track < hover < active hierarchy:
        ///   selected → 16% white (active, top of hierarchy)
        ///   hovered  → 10% white (medium wash, affordance)
        ///   rest     → transparent (track's 5% shows through)
        private func refreshMaterial() {
            let alpha: CGFloat
            if isSelected {
                alpha = 0.16
            } else if isHovered {
                alpha = 0.10
            } else {
                alpha = 0
            }
            background.layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
            refreshShortcutColor()
        }
    }

    /// The pill's shortcut badge.
    ///
    /// Non-interactive chrome sitting inside the tab's click target, so it
    /// hands pointer events to the title button instead of consuming them.
    /// Left as a plain sibling it would be a dead strip at the pill's trailing
    /// edge where clicking, dragging, and right-clicking the tab all stop
    /// working, since `TabPillCell` itself handles no mouse events.
    final class TabShortcutLabel: NSTextField {
        weak var pointerTarget: NSView?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil else { return nil }
            return pointerTarget ?? self
        }
    }

    /// Adaptive decorative stroke between neighboring inactive tab cells.
    /// It never participates in pointer routing or the accessibility tree.
    final class TabSeparatorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.separatorColor.setFill()
            NSBezierPath(rect: dirtyRect.intersection(bounds)).fill()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
}

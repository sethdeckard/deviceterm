// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabStripViewController: one window's tab strip + content swap,
// driven by observing its TabListViewModel. Menu actions dispatch routes
// through the Router instead of mutating tabs directly; the strip + the
// selected content view reconcile from state. The Detach/Shut-Down
// prompt stays here (CloseDecisions): the Router consumes whatever mode
// the user picks. When the tab list goes empty (close last tab), the
// window asks AppKit to close, which routes through `windowWillClose`.

import AppKit
import DaemonProtocol

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
    private let simResurrect: SimResurrect
    private let router: Router
    /// User-input verbs (menu actions, tab-button clicks, terminal
    /// onExit) flow through the dispatcher so the architecture
    /// stays "one resolver shared between CLI back-channel, deep
    /// links, AppleScript, and menus." Internal data-driven paths
    /// (sim-pane attach/detach driven by daemon events) stay on the
    /// Router because they already carry concrete IDs and don't
    /// need ref resolution.
    private let intentDispatcher: IntentDispatcher

    private var tabContentByID: [TabID: TabContentViewController] = [:]
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
    /// solo-pill max (at .defaultHigh priority so a narrow window can
    /// still shrink it). Without this, the cell sits at its intrinsic
    /// title width with no floor to widen it.
    private var soloPillTargetWidth: NSLayoutConstraint?
    /// Thin translucent track that sits behind the tab cells so the
    /// user sees a visible "lane" the pills rest in. Painted with a
    /// low-alpha white tint over the window background, which gives
    /// predictable contrast in any colorspace (NSVisualEffectView
    /// materials introduce a warm tint in dark mode that doesn't
    /// match Ghostty's clean dark look).
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
        simResurrect: SimResurrect,
        router: Router,
        intentDispatcher: IntentDispatcher,
        adopting: [(TabID, TabContentViewController)] = []
    ) {
        self.windowID = windowID
        self.tabListVM = tabListVM
        self.daemonClient = daemonClient
        self.simResurrect = simResurrect
        self.router = router
        self.intentDispatcher = intentDispatcher
        self.adopting = adopting
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Name a tab's pill and closer so a dump can tell one tab from another:
    /// both carry display titles, which collide freely. A tab whose short id
    /// is absent, which happens only against a pre-identifier-model daemon,
    /// is cleared rather than given a fallback format; clearing is the part
    /// that matters, since a leftover identifier still answers a lookup.
    ///
    /// Applied from the same-tabs path as well as the rebuild, because the
    /// primary terminal can change while the tab-ID list does not: close the
    /// first terminal of a split tab and the second becomes primary, carrying
    /// a different short id. Stamping only on rebuild would leave the pill
    /// naming a session that no longer backs the tab.
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

    /// SF Symbol prepended to automation-role tabs in the strip. The
    /// marker signals the automation role was minted by a human menu
    /// action, so the affordance is visible without being loud. Returns
    /// nil for `.agent` (the default).
    private static func automationMarker(role: SessionRole) -> NSImageView? {
        guard role == .automation else { return nil }
        // `wand.and.rays` is the platform's own automation vocabulary. A
        // key would read as "this opens something", which is backwards:
        // an automation grant is exactly what a protected tab refuses.
        // Subtle accent tint keeps it from competing with the title.
        let image = NSImage(
            systemSymbolName: "wand.and.rays",
            accessibilityDescription: "Automation tab"
        )
        let view = NSImageView()
        view.image = image
        view.contentTintColor = .controlAccentColor
        view.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .regular
        )
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.toolTip = "Automation tab (opened from the menu)"
        return view
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
        // in dark mode that doesn't match Ghostty's clean look):
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
        // Equal-to-constant at .defaultHigh: wants the solo pill at
        // its full target width; yields if a narrow window or stripFill
        // contradicts.
        let soloTarget = cellsContainer.widthAnchor.constraint(
            equalToConstant: Self.soloPillMaxConstant
        )
        soloTarget.priority = .defaultHigh
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

    override func viewDidAppear() {
        super.viewDidAppear()
        // observe() arms synchronously, so the first render() ran from
        // viewDidLoad with no window attached and its title / proxy-icon writes
        // went nowhere. Reapply now that the strip is in a window: an adopted
        // tear-off tab carries its label and OSC-7 path across with it, so no
        // further event is necessarily coming to trigger another pass.
        guard let index = tabListVM.selectedIndex,
            tabListVM.tabs.indices.contains(index),
            let tabContent = tabContentByID[tabListVM.tabs[index].id] else { return }
        applyWindowMetadata(for: tabContent)
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
    /// SimResurrect) before the controller drops out of the AppKit tree.
    func teardown() {
        observation?.cancel()
        observation = nil
        for tabContent in tabContentByID.values {
            tabContent.teardown()
        }
        tabContentByID.removeAll()
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
    // Each user-input verb constructs a `RouteIntent` and dispatches
    // through `IntentDispatcher`. `WindowRef.windowID(self.windowID)`
    // pins the action to THIS strip's window: `.current` would resolve
    // through the workspace selection, which can still name another
    // window at the instant a +/⌘T click lands in this one.
    // `TabRef.sessionId` is the unambiguous handle for per-tab
    // buttons (we hold the tabID, we look up the sessionId on the
    // way to the dispatcher). Dispatching through the intent layer
    // keeps menu/CLI/deep-link sources behind one resolver.

    @objc
    func newTab(_ sender: Any?) {
        dispatchIntent(
            .openTab(
            inWindow: .windowID(windowID),
            role: .agent,
            cwd: nil,
            cmd: nil
        )
            )
    }

    /// Shell → "Open Automation Tab". The product-UI path for
    /// minting a session with `.automation` role; no CLI verb
    /// emits this. The CLI back-channel encodes role as a string;
    /// menu emissions pass the typed `.automation` enum directly.
    @objc
    func openAutomationTab(_ sender: Any?) {
        dispatchIntent(
            .openTab(
            inWindow: .windowID(windowID),
            role: .automation,
            cwd: nil,
            cmd: nil
        )
            )
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
        requestCloseTab(id: tabID)
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
        guard let sessionId = tabListVM.tab(id: tabID)?.primaryTerminal.sessionId
        else { return }
        dispatchIntent(.selectTab(.sessionId(sessionId)))
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
        dispatchIntent(.selectTab(.sessionId(tab.primaryTerminal.sessionId)))
    }

    /// Fire-and-forget shape for menu / button handlers whose failure is
    /// benign (select, reorder): they trigger the GUI mutation and drop
    /// the result. Handlers whose rejection the human must see (protection)
    /// await the result and surface it themselves; don't route those
    /// through here.
    private func dispatchIntent(_ intent: RouteIntent) {
        let dispatcher = intentDispatcher
        Task { _ = await dispatcher.dispatch(intent, origin: .inProcess) }
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

    /// Forward an intent-layer `sendInput` to the named tab. Throws
    /// `IntentError.notFound` when the tab isn't hosted by this
    /// strip: the dispatcher relays the typed error back to the
    /// originating CLI so an automation sees "tab gone" rather
    /// than a misleading ok. Re-throws any error from the
    /// underlying VC chain (typically `TerminalSurfaceError.notAttached`
    /// when the tab's terminal couldn't bring up a surface).
    func sendInput(
        toTab tabID: TabID,
        text: String,
        typeDelayMillis: Int?
    ) throws {
        guard let tabContent = tabContentByID[tabID] else {
            throw IntentError.notFound(kind: "tab", ref: "\(tabID.value)")
        }
        try tabContent.sendInput(text, typeDelayMillis: typeDelayMillis)
    }

    /// Forward an intent-layer `captureTab` request to the named
    /// tab. Same notFound / re-throw shape as `sendInput`. Returns
    /// the captured viewport text.
    func captureTab(id tabID: TabID) throws -> String {
        guard let tabContent = tabContentByID[tabID] else {
            throw IntentError.notFound(kind: "tab", ref: "\(tabID.value)")
        }
        return try tabContent.captureScreen()
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
            let sessionId = tab.primaryTerminal.sessionId
            guard !sessionId.isEmpty else { return }
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
            switch TabCloseGateDecision.gate(
                simsAffected: affected,
                pinnedSimDecision: pinned,
                multiPane: paneCount > 1
            ) {
            case .simDisposition:
                // `tabClose` re-runs the lookup that just returned nil;
                // both reads happen in this same main-actor turn, so it
                // still misses and the prompt shows.
                let decision = CloseDecisions.tabClose(
                    config: config,
                    state: CloseSuppressionState.shared,
                    context: context
                )
                switch decision {
                case .detach:
                    self.dispatchIntent(.closeTab(.sessionId(sessionId), mode: .detach))

                case .shutdown:
                    self.dispatchIntent(.closeTab(.sessionId(sessionId), mode: .shutdown))

                case .cancel:
                    return
                }

            case let .multiPaneConfirm(mode):
                if CloseDecisions.multiPaneTabClose(
                    config: config,
                    state: CloseSuppressionState.shared,
                    context: context,
                    paneCount: paneCount
                ) {
                    self.dispatchIntent(.closeTab(.sessionId(sessionId), mode: mode))
                }

            case let .close(mode):
                self.dispatchIntent(.closeTab(.sessionId(sessionId), mode: mode))
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
            let mode: PaneCloseMode
            switch TabCloseGateDecision.gate(
                simsAffected: affected,
                pinnedSimDecision: pinned,
                multiPane: multiPaneTabCount > 0
            ) {
            case .simDisposition:
                let decision = CloseDecisions.bulkTabClose(
                    config: config,
                    state: CloseSuppressionState.shared,
                    context: context,
                    count: sessionIDs.count
                )
                switch decision {
                case .detach:
                    mode = .detach

                case .shutdown:
                    mode = .shutdown

                case .cancel:
                    return
                }

            case let .multiPaneConfirm(gateMode):
                guard CloseDecisions.bulkMultiPaneTabClose(
                    config: config,
                    state: CloseSuppressionState.shared,
                    context: context,
                    tabCount: sessionIDs.count,
                    multiPaneTabCount: multiPaneTabCount
                ) else { return }
                mode = gateMode

            case let .close(gateMode):
                mode = gateMode
            }
            for sessionId in sessionIDs {
                self.dispatchIntent(.closeTab(.sessionId(sessionId), mode: mode))
            }
        }
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
        let sessionId = tab.primaryTerminal.sessionId
        guard !sessionId.isEmpty else { return }
        // Toggle relative to what's shown *now* (effective-hidden), so a
        // menu action during an in-flight transition flips the right way.
        let makeProtected = !tab.isEffectivelyProtected
        let dispatcher = intentDispatcher
        Task { @MainActor [weak self] in
            let result = await dispatcher.dispatch(
                .setTabProtected(.sessionId(sessionId), isProtected: makeProtected),
                origin: .inProcess
            )
            // Unlike a CLI caller, the human at the protection menu has no
            // result stream to read: surface a rejection as an alert rather
            // than dropping it silently. The tab stays fail-closed, so a
            // failed "protect" leaves it hidden but unconfirmed; the user
            // needs to know it didn't take.
            if case let .error(error) = result {
                self?.presentProtectionChangeFailure(makeProtected: makeProtected, error: error)
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
        dispatchIntent(
            .openTab(
                inWindow: .windowID(windowID),
                role: role,
                cwd: cwd,
                cmd: nil
            )
        )
    }

    @objc
    func newTabFromMenu(_ sender: NSMenuItem) {
        // Identical to ⌘T / the strip's "+" button. Provided in the
        // context menu so the right-click is a one-stop surface.
        dispatchIntent(
            .openTab(
                inWindow: .windowID(windowID),
                role: .agent,
                cwd: nil,
                cmd: nil
            )
        )
    }

    @objc
    func openAutomationTabFromMenu(_ sender: NSMenuItem) {
        dispatchIntent(
            .openTab(
                inWindow: .windowID(windowID),
                role: .automation,
                cwd: nil,
                cmd: nil
            )
        )
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
        // Create VCs for new tabs. Failures show an alert; the Router has
        // already minted the daemon session, so a provisioning failure
        // here strands it until the user closes the tab.
        for tab in tabs where tabContentByID[tab.id] == nil {
            do {
                let tabContent = try TabContentViewController(
                    tabID: tab.id,
                    windowID: windowID,
                    primary: tab.primaryTerminal,
                    sessionName: tab.primaryTerminal.name,
                    role: tab.role,
                    tabListVM: tabListVM,
                    daemonClient: daemonClient,
                    simResurrect: simResurrect,
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
        let dispatcher = self.intentDispatcher
        let tabID = tabContent.tabID
        tabContent.onTerminalExit = { [weak tabContent] terminalID in
            guard let tabContent else { return }
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
            // Last terminal in this tab: close the whole tab through
            // the dispatcher. Use the primary terminal's sessionId
            // since that's the only one remaining at this point.
            let sessionId = tabContent.sessionId
            Task {
                _ = await dispatcher.dispatch(
                    .closeTab(.sessionId(sessionId), mode: .detach),
                    origin: .inProcess
                )
            }
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
        // Min 180 per cell lives at .defaultHigh so a narrow window with
        // many tabs shrinks gracefully past 180 instead of producing an
        // unsatisfiable required-constraint conflict.
        stripFillTrailing?.isActive = tabs.count >= 2
        soloPillMaxWidth?.isActive = tabs.count == 1
        soloPillTargetWidth?.isActive = tabs.count == 1
        for (idx, tab) in tabs.enumerated() {
            guard let tabContent = tabContentByID[tab.id] else { continue }
            let title = TabTitleButton(
                title: tabContent.displayTitle,
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
            Self.applyAccessibilityIdentifiers(
                pill: title, close: close, shortId: tab.primaryTerminal.shortId
            )
            // Reserve space always but fade alpha 0 → 1 on hover so
            // entering the cell doesn't reflow the layout.

            var otherViews: [NSView] = [title]
            if let marker = Self.automationMarker(role: tab.role) {
                // Marker sits between the close and the title.
                otherViews.insert(marker, at: 0)
            }
            let cell = TabPillCell(frame: .zero)
            cell.install(close: close, otherViews: otherViews)
            cell.onHoverChange = { [weak self] in self?.applySeparators() }
            // The whole pill is the drag image.
            title.snapshotSource = cell
            cell.translatesAutoresizingMaskIntoConstraints = false
            // Pin the pill height: the strip is 34pt and the cell
            // centers at 28pt with .centerY alignment on the cells
            // container, giving 3pt margin top/bottom. The track is
            // pinned to the same 28pt extent below.
            cell.heightAnchor.constraint(equalToConstant: 28).isActive = true
            // Min 180 at .defaultHigh: required would cause an
            // unsatisfiable constraint set on a narrow window with many
            // tabs (e.g. 5 tabs × 180 = 900 > 800 minSize). Lower
            // priority lets cells shrink past 180 instead.
            let minWidth = cell.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
            minWidth.priority = .defaultHigh
            minWidth.isActive = true
            cellsContainer.insertArrangedSubview(cell, at: idx)
        }
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

    private func applySelection(for tabs: [TabState]) {
        guard let index = tabListVM.selectedIndex,
            tabs.indices.contains(index),
            let tabContent = tabContentByID[tabs[index].id] else { return }
        let selectedID = tabs[index].id
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
        }
        applySeparators()
        applyWindowMetadata(for: tabContent)

        // Only swap the content view and refocus on a *real* selection
        // change: a title/CWD-driven re-render must not steal first
        // responder from a sim pane the user focused.
        if selectionChanged {
            content.subviews.forEach { $0.removeFromSuperview() }
            tabContent.view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(tabContent.view)
            NSLayoutConstraint.activate(
                [
                tabContent.view.topAnchor.constraint(equalTo: content.topAnchor),
                tabContent.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                tabContent.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                tabContent.view.trailingAnchor.constraint(equalTo: content.trailingAnchor)
                ]
                )
            tabContent.primaryTerminalVC()?.focus()
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

    private func updateStripLabels(for tabs: [TabState]) {
        for (idx, tab) in tabs.enumerated() {
            // Look up by TabID rather than array index: same reasoning
            // as `applySelection`'s TabID-keyed loop.
            guard let cell = cell(forTab: tab.id),
                let button = cell.titleButton,
                let tabContent = tabContentByID[tab.id] else { continue }
            button.title = tabContent.displayTitle
            Self.applyAccessibilityIdentifiers(
                pill: button, close: cell.closeButton, shortId: tab.primaryTerminal.shortId
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
        stripDraggingUpdated(sender)
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

/// NSStackView subclass that reports its empty regions as draggable, so
/// click-and-drag on the strip background moves the window (the same
/// machinery the standard title bar uses). NSButton subviews (the tab
/// pills, "✕" close, and "+" add) consume their own clicks via the
/// normal responder chain; only mouse-downs that miss every button reach
/// this view, where `mouseDownCanMoveWindow` lets AppKit take over.
private final class DraggableStackView: NSStackView {
    /// When set (the cells container), tab-drag callbacks forward to the
    /// strip VC so it (not the view) owns the reorder/relocate logic.
    /// The outer strip leaves this nil and never registers dragged types,
    /// so only the cells lane accepts drops.
    weak var dropDelegate: TabStripViewController?
    override var mouseDownCanMoveWindow: Bool { true }

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
private final class TabTitleButton: NSButton, NSDraggingSource {
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
                let point = convert(next.locationInWindow, from: nil)
                if !didDrag, bounds.contains(point), let action {
                    _ = sendAction(action, to: target)
                }

            default:
                break
            }
        }
        mouseDownPoint = nil
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
private final class DraggableRootView: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

/// "+" new tab button: circular and visually tied to the tab strip via
/// the same three-level white-alpha hierarchy the tab pills use
/// (track 5% at rest → hover 10% → pressed 16% matching the active
/// tab). Subclasses `NSControl` rather than `NSButton` so no
/// `NSButtonCell` participates in layout: image-only NSButtons with
/// a bezelStyle (or even a default cell) impose their own minimum
/// height regardless of `intrinsicContentSize` overrides or required
/// width/height constraints, which forces a vertical-pill shape.
final class NewTabButton: NSControl {
    private var hovered = false {
        didSet { refreshFill() }
    }
    private var pressed = false {
        didSet { refreshFill() }
    }
    private let plusImageView = NSImageView()

    override var intrinsicContentSize: NSSize {
        NSSize(width: 28, height: 28)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        toolTip = "New Tab"
        // An NSControl carrying no cell publishes nothing to the
        // accessibility tree, and AppKit prunes a view that is not an
        // accessibility element, so the plus image below never surfaces
        // either. Sidestepping NSButtonCell for layout costs the role and
        // label a button would have supplied; declare them here instead, or
        // this affordance is reachable by mouse only.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Tab")
        // The label is also the New Tab menu item's exact title, so a search
        // by label matches two real elements. The identifier is what names
        // this one.
        setAccessibilityIdentifier(TabAccessibilityIdentity.newTabButton)

        plusImageView.translatesAutoresizingMaskIntoConstraints = false
        plusImageView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        plusImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .medium
        )
        plusImageView.contentTintColor = .secondaryLabelColor
        plusImageView.imageScaling = .scaleNone
        addSubview(plusImageView)

        let widthConstraint = widthAnchor.constraint(equalToConstant: 28)
        widthConstraint.priority = .required
        let heightConstraint = heightAnchor.constraint(equalToConstant: 28)
        heightConstraint.priority = .required
        let aspect = widthAnchor.constraint(equalTo: heightAnchor)
        aspect.priority = .required

        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            aspect,
            plusImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            plusImageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setContentHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        refreshFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
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

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// Route an accessibility press through the same dispatch the mouse path
    /// uses. With no cell there is nothing to turn a press into target/action
    /// on its own, so publishing the button role without this would leave the
    /// affordance visible to assistive technology and inert.
    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }
        return sendAction(action, to: target)
    }

    /// Track press / release manually since there's no NSButtonCell
    /// driving the click cycle. mouseUp inside bounds fires the
    /// target/action; `super.sendAction(_:to:)` routes through
    /// NSControl's standard dispatch.
    override func mouseDown(with event: NSEvent) {
        pressed = true
        var dragging = true
        while dragging {
            guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else {
                break
            }
            switch next.type {
            case .leftMouseDragged:
                let point = convert(next.locationInWindow, from: nil)
                pressed = bounds.contains(point)

            case .leftMouseUp:
                let point = convert(next.locationInWindow, from: nil)
                let inside = bounds.contains(point)
                dragging = false
                pressed = false
                if inside, let action {
                    _ = sendAction(action, to: target)
                }

            default:
                break
            }
        }
    }

    private func refreshFill() {
        let alpha: CGFloat
        if pressed {
            alpha = 0.16
        } else if hovered {
            alpha = 0.10
        } else {
            alpha = 0.05
        }
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }
}

/// One custom tab cell that:
///
///   - paints its background via explicit white-alpha tints over the
///     window's ghostty bg color (5% track → 10% hover → 16% selected),
///     giving clean, predictable contrast that NSVisualEffectView
///     materials would warm with dark-mode tints
///   - lays out `[✕, marker?, title]` as a horizontal NSStackView, with
///     the close ✕ leftmost and the title filling the rest of the width
///   - reserves space for the close button always (alpha-fades it on
///     hover rather than `isHidden`-toggling) so the layout doesn't
///     jitter when the cursor enters
///
/// Selection comes from the strip controller; the cell tracks hover and
/// paints both states.
private final class TabPillCell: NSView {
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

    /// Title button accessor: always the LAST arranged subview after
    /// `install` (close is leftmost; an optional marker sits between).
    /// Used by the strip VC's TabID-keyed lookup.
    var titleButton: NSButton? {
        stack.arrangedSubviews.last as? NSButton
    }

    private let background = NSView()
    private let stack = NSStackView()
    private let trailingSeparator = TabSeparatorView()

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

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingSeparator.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingSeparator.widthAnchor.constraint(equalToConstant: 1),
            trailingSeparator.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Mount the subviews. The caller passes [marker?, title]; the close
    /// button is added leftmost separately so it has a stable position.
    func install(close: NSButton, otherViews: [NSView]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        closeButton = close
        close.alphaValue = 0
        stack.addArrangedSubview(close)
        for view in otherViews { stack.addArrangedSubview(view) }
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
    }
}

/// Adaptive decorative stroke between neighboring inactive tab cells.
/// It never participates in pointer routing or the accessibility tree.
private final class TabSeparatorView: NSView {
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

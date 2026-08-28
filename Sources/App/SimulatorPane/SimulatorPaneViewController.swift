// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import IOSurface
import class SwiftUI.NSHostingController
import class SwiftUI.NSHostingView
import UniformTypeIdentifiers

/// The AppKit view glue for one
/// attached simulator or physical-device pane. Thin shell over the decomposed
/// pieces: Metal/IOSurface rendering + input synthesis live in
/// `SimulatorContentView`, pure gesture math in `SimGestureMath`,
/// the state machine in `SimPaneReducer`, and presentation state +
/// daemon I/O in `SimulatorPaneViewModel`. What's left here: build
/// the views, bind to the VM via `observe()`, forward input-delegate
/// callbacks to VM intents, and surface the owner-facing
/// close/reboot/state callbacks.
@MainActor
final class SimulatorPaneViewController: NSViewController, SimulatorInputDelegate {
    // Identity forwarded from the VM for external callers (PaneLayoutViewController
    // sizes by `family`, finds panes by `udid`; TabContentViewController keys on it).
    var udid: String { viewModel.udid }
    var displayName: String { viewModel.displayName }
    var family: String { viewModel.family }
    var paneId: String { viewModel.paneId }
    /// Per-pane device-control capabilities. Drives affordance gating
    /// (which menu / chrome controls are enabled) via
    /// `PaneControlAffordance`. A sim reports the full set; a device a
    /// subset.
    var capabilities: PaneCapabilities { viewModel.capabilities }
    /// Whether this pane mirrors a physically-connected device rather
    /// than a CoreSimulator. Set at construction from the pane target;
    /// read by the affordance gate to disable simulator-only actions.
    let isPhysicalDevice: Bool
    var simulatorPaneSupportsLiveTouchInput: Bool {
        viewModel.supportsLiveTouchInput
    }
    var simulatorPaneSupportsMultitouchInput: Bool {
        viewModel.supportsMultitouchInput
    }
    /// Whether a live bottom-edge mouse drag drives the system gesture
    /// (App Switcher / home indicator), following the cursor until release.
    /// Both pane kinds support it, realized differently in the daemon: the
    /// simulator tags the contacts with an `IndigoHIDEdge`; the physical device
    /// streams enriched system-gesture touch reports (a plain digitizer touch
    /// would hit the foreground app and just scroll). Gated on live-touch
    /// input, which both kinds have.
    var simulatorPaneSupportsEdgeGesture: Bool {
        viewModel.supportsLiveTouchInput
    }
    /// Read-only mirror of the VM's lifecycle state. Lets owners poll
    /// for transitions (e.g. the Device > Reboot flow waiting for
    /// `.shutdown` before issuing the boot RPC) without exposing the
    /// VM itself.
    var currentState: SimulatorPaneState { viewModel.state }

    private let viewModel: SimulatorPaneViewModel
    /// SwiftUI chrome overlay state (title strip, status badge, focus
    /// ring, ribbon controls). Owned here
    /// so the VC can mutate via intent methods; SwiftUI observes the
    /// `@Observable` model natively and re-renders without going
    /// through `observe()`. AppKit-side surfaces (the wrapper's focus
    /// border) read it through `observe()` → `render()`.
    let chromeViewModel: PaneChromeViewModel
    /// Tab id this sim pane belongs to, used as the drag-payload tab
    /// match-check when the chrome strip initiates a pane drag.
    /// Settable so `TabContentViewController` can wire it after
    /// construction; nil disables drag. Mirrors the same surface as
    /// `TerminalPaneViewController.tabID`.
    var tabID: TabID? {
        didSet { chromeHostView?.tabID = tabID }
    }
    private var chromeHostView: PaneChromeDragHostView<PaneChromeOverlay>?
    private var contentView: SimulatorContentView?
    private var wrapperView: SimulatorPaneWrapperView?
    /// AX inspector side panel, mounted on the right side of the
    /// sim pixels when `axInspectorEnabled` is on, hidden otherwise.
    /// The panel hosts a `SimulatorPaneAXInspector` SwiftUI view
    /// backed by `axViewModel`, which mirrors
    /// `chromeViewModel.axInspectorLabel` so the panel re-renders on
    /// every tracked element-under-cursor update.
    let axViewModel = SimulatorPaneAXViewModel()
    /// Device ▸ Location state for this pane. Read by
    /// `LocationMenuController` when the submenu opens; `internal` so
    /// both that controller and tests can reach it.
    let locationViewModel: PaneLocationViewModel
    private var axPanelHost: NSHostingView<SimulatorPaneAXInspector>?
    private var contentTrailingToWrapperEdge: NSLayoutConstraint?
    private var contentTrailingToAxPanel: NSLayoutConstraint?
    private var axPanelTrailingConstraint: NSLayoutConstraint?
    private var axPanelTopConstraint: NSLayoutConstraint?
    private var axPanelBottomConstraint: NSLayoutConstraint?
    private var axPanelWidthConstraint: NSLayoutConstraint?
    private var contentMinWidthConstraint: NSLayoutConstraint?
    /// Set by `PaneLayoutViewController` when the sim is newly attached
    /// or has just been rearranged into a new split. The render pass
    /// applies Point Accurate sizing once both pixel dimensions land
    /// (from the IOSurface) and the wrapper has a window, then
    /// clears the flag so subsequent user resizes stick. Without
    /// this gating, the auto-fit would run before dims arrive and
    /// silently no-op, leaving the pane chunky.
    var pendingAutoFit: Bool = false
    /// The preset the auto-fit pass replays, so a deliberately-chosen
    /// Pixel Accurate / Point Accurate pane keeps that sizing when
    /// it moves to a new split, instead of springing back to fit.
    /// Stamped in `viewDidLoad` from `restoredPreset`, or from a
    /// family-aware default when the pane carries none, because
    /// watch's tiny native screen would look comically wide when
    /// Fit-Screen'd into a full-window pane, so watches default
    /// to Point Accurate (a ~250pt-wide compact size); the other
    /// families default to Fit Screen so a phone/pad/tv fills any
    /// reasonable pane bounds.
    private var lastAppliedPreset: SimSizePreset = .fitScreen
    /// The preset the pane state arrived carrying, so a pane whose view
    /// controller was rebuilt keeps the sizing the user chose instead of
    /// falling back to the family default. Nil when the pane state carries
    /// no preset, which is what selects that default.
    private let restoredPreset: SimSizePreset?
    private let overlay = NSTextField(labelWithString: "")
    /// Semi-transparent scrim behind the overlay text/buttons so the
    /// shutdown message stays readable over the frozen last frame.
    private let dimView = NSView()
    /// Held so the shutdown overlay can hide it for a physical device, whose
    /// pane wires no reboot action.
    private lazy var rebootButton = NSButton(
        title: "Reboot",
        target: self,
        action: #selector(rebootClicked(_:))
    )
    private lazy var shutdownButtons: NSStackView = {
        let closeButton = NSButton(
            title: "Close Pane",
            target: self,
            action: #selector(closePaneClicked(_:))
        )
        let stack = NSStackView(views: [closeButton, rebootButton])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        return stack
    }()
    private var observation: ObservationToken?
    /// Last state pushed to `onStateChange`, so the callback fires once
    /// per transition (the initial `.booting` is not re-announced).
    private var lastNotifiedState: SimulatorPaneState = .booting

    /// Fires when the user clicks "Close Pane" on the shutdown overlay.
    /// The owning TabContentViewController removes this pane and releases ownership.
    var onClose: (() -> Void)?
    /// Fires when the user clicks "Reboot" on the shutdown overlay. The
    /// owner re-boots the device and the auto-resurrect poll re-attaches.
    var onReboot: (() -> Void)?
    /// Fires from the Device > Reboot menu item while the sim is still
    /// rendering. The owner shuts the sim down and boots it again,
    /// preserving ownership. Distinct from `onReboot` (which only
    /// boots, for the shutdown-overlay path); the menu can be hit at
    /// any time so the owner has to sequence both halves.
    var onLiveReboot: (() -> Void)?
    /// Fires from the Device > Erase All Content menu item after the
    /// user has confirmed in the alert. Owner sequences shutdown →
    /// `simctl erase <udid>` → boot, preserving ownership.
    var onEraseContent: (() -> Void)?
    /// Fires from the Device > Screenshot menu item. Owner picks the
    /// output path and shells out to `simctl io screenshot`.
    var onScreenshot: (() -> Void)?
    /// Fires from the Device > Record menu item when no recording is
    /// in progress (the VC's `recordingProcess` is nil). Owner starts
    /// `simctl io recordVideo` and stores the resulting Process on
    /// the VC so the next menu click toggles to stop.
    var onRecordStart: (() -> Void)?
    /// Fires from the Device > Record menu item while a recording is
    /// in progress. Owner sends SIGINT to `recordingProcess`, awaits
    /// the flush, reveals the output file in Finder, and clears the
    /// process ref. Title-toggling on the menu item picks the right
    /// callback per click.
    var onRecordStop: (() -> Void)?
    /// Active simctl recordVideo process. Set by the owner's
    /// `onRecordStart` callback; cleared by `onRecordStop`. The @objc
    /// selector reads this to decide whether the click starts or
    /// stops a recording, and `validateUserInterfaceItem` reads it
    /// to label the menu item accordingly. Nil = no recording.
    ///
    /// `didSet` mirrors into `chromeViewModel.recordingActive` because
    /// this var isn't `@Observable`; the chrome's record button label
    /// would otherwise go stale until something else fires `render()`.
    /// (`render()` ALSO syncs the same field on every pass so a
    /// race-free first paint still works, but a live toggle depends on
    /// this didSet.)
    var recordingProcess: Process? {
        didSet { chromeViewModel.recordingActive = recordingProcess != nil }
    }
    /// Fires from the Device > Open in Apple Simulator.app menu item.
    /// Owner launches Apple's `Simulator.app` (canonical Xcode path)
    /// with `-CurrentDeviceUDID <udid>` so it foregrounds this sim's
    /// window. Fire-and-forget, with no state to track.
    var onOpenInSimulatorApp: (() -> Void)?
    /// Fires from the Device > Install App… menu item with the bundle
    /// the user picked in the NSOpenPanel. Owner shells out to
    /// `simctl install <udid> <bundleURL>` and surfaces the result.
    /// The .app / .ipa filter lives in the VC's selector; the owner
    /// receives an already-validated URL.
    var onInstallApp: ((URL) -> Void)?
    /// Fires from the right-click Shut Down menu item, distinct
    /// from Reboot in that it doesn't boot afterwards. Owner calls
    /// `daemon.shutdownDevice`; the pane lifecycle event then drives
    /// the shutdown overlay as usual (and the existing Reboot
    /// button on that overlay is the recovery path).
    var onShutDownSim: (() -> Void)?
    /// Fires from the right-click Reveal in Finder menu item. Owner
    /// opens the sim's CoreSimulator device folder in Finder so the
    /// user can poke at app data / logs / preferences without
    /// hunting for the UDID path manually.
    var onRevealInFinder: (() -> Void)?
    /// Fires on every (deduped) state transition. The pane's owner uses this to
    /// manage its resurrect watch when a pane enters or leaves shutdown:
    /// `SimPaneActionCoordinator` for a sim, `TabContentViewController` for a
    /// device.
    var onStateChange: ((SimulatorPaneState) -> Void)?
    /// Fires when the user picks a size preset the pane wasn't already on.
    /// The owner records it in nav state, which is what carries the choice
    /// across the view controller being rebuilt.
    var onSizePresetChange: ((SimSizePreset) -> Void)?
    /// Fires when keyboard focus arrives at this pane. The owner stamps
    /// the tab's remembered pane so selecting the tab again comes back
    /// here. Only the arriving edge, since losing focus to a sibling is
    /// that sibling's turn to be remembered.
    var onFocusGained: (() -> Void)?

    /// Held for the AX inspector path, since `paneAxPoint` lives on a
    /// separate role protocol that the VM doesn't need. Stored on the
    /// VC because the chrome's mouse-tracking → AX query → label
    /// update flow is VC-orchestrated (the VM owns input dispatch,
    /// not chrome side effects).
    private let axDaemonClient: any PaneAccessibilityControlling
    /// Throttle gate for the AX hover query: only one in flight at a
    /// time, with a minimum interval between requests so a fast mouse
    /// move doesn't flood the daemon.
    private var axQueryInFlight: Bool = false
    private var lastAxQueryTime: Date?
    /// Optional tracking area installed when the AX inspector is on so
    /// mouseMoved events fire even when the pane isn't first responder.
    /// Removed on toggle-off.
    private var axTrackingArea: NSTrackingArea?

    /// Advisory state for the task `viewDidLoad` schedules. Injected
    /// rather than taken from `HeadlessAdvisoryViewModel.shared` so a
    /// pane built by a test reads neither the live config nor running
    /// application state, and so cannot raise the modal that would
    /// block the suite.
    private let advisory: HeadlessAdvisoryViewModel

    /// Build a sim pane view from already-attached daemon state. The
    /// Router does device.attach (in its attachSimPane handler) and
    /// records the SimPaneState; the glue then creates this VC for it.
    convenience init(
        simPane: SimPaneState,
        daemonClient: any PaneControlling & PaneSubscribing & PaneAccessibilityControlling
            & PaneLocationControlling,
        locations: any LocationsStoring = LocationsFileStore(),
        advisory: HeadlessAdvisoryViewModel = .shared
    ) {
        self.init(
            mirroredPane: simPane,
            daemonClient: daemonClient,
            locations: locations,
            advisory: advisory
        )
    }

    /// Shared construction for any device-mirroring pane: a
    /// CoreSimulator (`SimPaneState`) or a physically-connected device
    /// (`DevicePaneState`). Both conform to `MirroredPaneState`, so the
    /// renderer + view model build off exactly these backend-neutral
    /// fields; the two kinds differ only in the owner-facing callbacks
    /// the reconcile wires afterward (a device pane gets close, not the
    /// sim-only erase / open-in-Simulator / live-reboot set). This is
    /// the breadcrumb seam toward a future single target-keyed pane
    /// type. The VM's `udid` slot carries the backend-neutral identity
    /// key (`target.key`, a UDID for a sim or a deviceId for a device);
    /// the VM uses it for display / external lookup only, keying all
    /// daemon I/O off `paneId`.
    init(
        mirroredPane: any MirroredPaneState,
        daemonClient: any PaneControlling & PaneSubscribing & PaneAccessibilityControlling
            & PaneLocationControlling,
        locations: any LocationsStoring = LocationsFileStore(),
        advisory: HeadlessAdvisoryViewModel = .shared
    ) {
        self.advisory = advisory
        self.restoredPreset = mirroredPane.sizePreset
        self.viewModel = SimulatorPaneViewModel(
            paneId: mirroredPane.paneId,
            daemonClient: daemonClient,
            udid: mirroredPane.target.key,
            displayName: mirroredPane.displayName,
            family: mirroredPane.family,
            attachment: mirroredPane.attachment,
            capabilities: mirroredPane.capabilities
        )
        self.locationViewModel = PaneLocationViewModel(
            paneId: mirroredPane.paneId,
            client: daemonClient,
            locations: locations
        )
        self.axDaemonClient = daemonClient
        let isPhysicalDevice: Bool
        if case .device = mirroredPane.target {
            isPhysicalDevice = true
        } else {
            isPhysicalDevice = false
        }
        self.isPhysicalDevice = isPhysicalDevice
        self.chromeViewModel = PaneChromeViewModel(
            title: mirroredPane.displayName,
            family: mirroredPane.family,
            capabilities: mirroredPane.capabilities ?? .missingBlockFallback,
            isPhysicalDevice: isPhysicalDevice,
            devicePixelWidth: mirroredPane.pixelWidth,
            devicePixelHeight: mirroredPane.pixelHeight
        )
        super.init(nibName: nil, bundle: nil)
        title = mirroredPane.displayName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Chrome height: uniform 28pt across every device family. The
    /// chrome is a single-row collapsible ribbon (`PaneChromeOverlay`),
    /// so no family reserves an extra row for hardware buttons; those
    /// live in the ribbon's expanded state and the ⋯ menu. The function
    /// stays parameterized on family so a family that needs mandatory
    /// always-visible chrome can opt into a two-row layout.
    static func chromeHeight(forFamily family: String) -> CGFloat {
        28
    }

    override func loadView() {
        let content = SimulatorContentView()
        content.inputDelegate = self
        // Producer stamps only physical-device frames, so only device panes
        // trace on the consumer side; sim panes leave this nil.
        content.tracePaneId = isPhysicalDevice ? viewModel.paneId : nil
        // Right-click on the sim pane surfaces the same sim actions
        // the menu bar exposes. AppKit handles the popup lifecycle
        // off `view.menu`; the menu items target the responder chain,
        // which lands here on this VC.
        content.menu = makeSimulatorPaneContextMenu()
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView = content
        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(0.6).cgColor
        dimView.isHidden = true
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.alignment = .center
        overlay.textColor = .white
        overlay.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        overlay.isHidden = true
        // Booting / shutdown messages + the dim scrim live inside the
        // Metal-hosting `content` view so they cover only the sim
        // picture and not the chrome strip above it.
        content.addSubview(dimView)
        content.addSubview(overlay)
        content.addSubview(shutdownButtons)
        NSLayoutConstraint.activate(
            [
            dimView.topAnchor.constraint(equalTo: content.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dimView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            shutdownButtons.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            shutdownButtons.topAnchor.constraint(
                equalTo: overlay.bottomAnchor,
                constant: 12
            )
            ]
            )

        // Wrapper holds chrome strip (top, fixed height) + content
        // view (fills the rest). Chrome and Metal surface are
        // siblings, not overlays, so the chrome occupies reserved
        // space and the device name never paints over the sim
        // picture.
        //
        // The chrome host is a `PaneChromeDragHostView` (same wrapper
        // the terminal pane chrome uses) so the sim chrome is also a
        // pane-drag source: the user can grab the strip and drop
        // the pane onto a sibling to rearrange.
        // `showsGrabCursor: true` so the cursor flips to openHand on
        // hover over the chrome bar, a visible affordance that the
        // pane can be dragged from here. SwiftUI buttons inside the
        // ribbon override the cursor with their own when hovered, so
        // there's no clash; the openHand shows over the badge/title
        // area and any empty space inside the chrome.
        let chromeHost = PaneChromeDragHostView(
            rootView: PaneChromeOverlay(viewModel: chromeViewModel),
            showsGrabCursor: true
        )
        chromeHost.tabID = tabID
        chromeHost.slot = .sim(udid: viewModel.udid)
        // A click on the chrome strip should focus this pane. The
        // wrapper's `becomeFirstResponder` forwards to the Metal
        // content view via `inputTarget`, which calls back through
        // SimulatorInputDelegate and lights up the focus border.
        chromeHost.focusReceiver = content
        chromeHost.translatesAutoresizingMaskIntoConstraints = false
        chromeHostView = chromeHost
        let wrapper = SimulatorPaneWrapperView(frame: .zero)
        wrapper.inputTarget = content
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(chromeHost)
        wrapper.addSubview(content)
        // Bezel sits between the wrapper and the Metal content
        // view. The Metal view's clearColor is (0,0,0,0), so its
        // letterbox region is transparent and the bezel paints
        // through. `installBezelLayer` keeps subview ordering
        // authoritative on the wrapper side.
        wrapper.installBezelLayer(belowContentView: content)
        // Watch Digital Crown bump on the bezel routes through the
        // same VM closures the chrome ribbon's crown buttons use.
        // Non-watch families get a `.zero` crown rect from the
        // bezel layout math, so these stay unreachable on phone /
        // pad / tv.
        wrapper.onCrownPress = { [weak self] in
            self?.viewModel.pressButton(.digitalCrown)
        }
        wrapper.onCrownUp = { [weak self] in
            self?.viewModel.crown(delta: -1)
        }
        wrapper.onCrownDown = { [weak self] in
            self?.viewModel.crown(delta: 1)
        }
        // Mirror the wrapper's resolved focus into the chrome's view
        // model, where SwiftUI observes it for the title brightening.
        // The wrapper resolves from the responder chain, so this is a
        // one-way copy of that answer, never a second source for it.
        wrapper.onFocusChange = { [weak self] focused in
            self?.chromeViewModel.isFocused = focused
            if focused { self?.onFocusGained?() }
        }
        wrapperView = wrapper
        // Snapshot the entire wrapper (chrome + Metal sim view) when
        // a drag starts so the user drags a translucent miniature of
        // the whole pane.
        chromeHost.snapshotSource = wrapper
        // Uniform 28pt row for every family (see
        // `chromeHeight(forFamily:)`). The host's intrinsic content
        // size matches because SwiftUI sizes to its actual content.
        let chromeHeight: CGFloat = Self.chromeHeight(forFamily: viewModel.family)
        let contentTrailing = content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        contentTrailingToWrapperEdge = contentTrailing
        NSLayoutConstraint.activate(
            [
            chromeHost.topAnchor.constraint(equalTo: wrapper.topAnchor),
            chromeHost.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            chromeHost.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            chromeHost.heightAnchor.constraint(equalToConstant: chromeHeight),
            content.topAnchor.constraint(equalTo: chromeHost.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            contentTrailing,
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor)
            ]
            )
        view = wrapper
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        wireChromeActions()
        // A pane whose state carries a preset keeps it: this view controller
        // is rebuilt whenever the daemon record behind the pane is replaced,
        // and the choice would otherwise reset every time.
        //
        // Otherwise, a family-aware default. Watch sims have tiny
        // native screens (~395pt); Fit Screen on a full-window
        // pane would aspect-fit a watch into a comically wide
        // frame, so they default to Point Accurate (compact). The
        // other families fill any reasonable pane with Fit Screen.
        lastAppliedPreset = restoredPreset
            ?? (DeviceFamily(wire: viewModel.family) == .watch ? .pointAccurate : .fitScreen)
        // Left nil for a pane with no restored preset, so the chrome picker
        // shows no checkmark until something applies one.
        chromeViewModel.selectedPreset = restoredPreset
        // `App.`-qualified: NSObject's KVO `observe` shadows the global.
        observation = App.observe { [weak self] in self?.render() }
        viewModel.start()
        // Begin loading the location snapshot for a later menu open. It
        // completes asynchronously, so an immediate open can still draw
        // the empty starting snapshot.
        locationViewModel.refresh()
        // Run after viewDidLoad returns so the pane finishes layout
        // before the modal appears. This is Apple's Simulator.app
        // coexistence advisory, gated to fire at most once per launch (and once
        // ever if the user checks "Don't show again").
        Task { @MainActor [advisory] in
            HeadlessAdvisory.presentIfNeeded(viewModel: advisory)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Off-window layout passes report bounds that no user ever sees,
        // so they can't settle the fit.
        guard view.window != nil else { return }
        applyLaunchRibbonFit(paneWidth: view.bounds.width)
    }

    /// Open the ribbon when the pane is wide enough to show it beside
    /// the full device name; otherwise leave it collapsed. Decides
    /// exactly once, on the first layout pass that can see the width
    /// the user will actually get, then never revisits it: from there
    /// the chevron is the only thing that moves the ribbon, so window
    /// resizes and divider drags leave it alone.
    ///
    /// `pendingAutoFit` is what identifies that pass. A pane's width
    /// moves twice on the way up: the split seeds synthetic ratios
    /// against zero bounds, then the size-preset auto-fit resizes it
    /// once the IOSurface publishes pixel dimensions. Both auto-fit
    /// entry points (`tryAutoFitNow` and `render`) clear the flag and
    /// call `applySizePreset` in the same synchronous step, and that
    /// method only forces layout *after* moving the divider, so no
    /// pass can arrive with the flag down and a stale width. The flag
    /// is armed inside `reconcile`, before AppKit's first real layout
    /// cycle, so a freshly attached pane is never measured early.
    ///
    /// Deliberately not a "wait for the width to stop changing" latch:
    /// AppKit makes no promise about how many layout passes a settled
    /// pane gets, and a launch that produced a single pass would leave
    /// the decision open for a later resize to reopen.
    ///
    /// A pane whose auto-fit never lands (pixel dimensions never
    /// arrive, e.g. a sim that fails to boot) remains undecided and
    /// stays collapsed.
    ///
    /// Takes the width as a parameter rather than reading `view.bounds`
    /// so tests can drive the sequence without standing up a window.
    func applyLaunchRibbonFit(paneWidth: CGFloat) {
        guard !chromeViewModel.ribbonExpansionDecided,
            !pendingAutoFit,
            paneWidth > 0 else { return }
        chromeViewModel.ribbonExpanded = PaneChromeRibbonFit.fitsExpanded(
            paneWidth: paneWidth,
            titleWidth: PaneChromeRibbonFit.titleWidth(chromeViewModel.title),
            actionCount: chromeViewModel.ribbonActions.count
        )
        chromeViewModel.ribbonExpansionDecided = true
    }

    /// Pull keyboard focus to this pane. Wired into every chrome
    /// action so clicking a SwiftUI button on the strip (which
    /// claims the hit itself, bypassing the drag wrapper's
    /// mouseDown focus path) still lights up the focus border and
    /// stamps `lastFocusedTerminal`-equivalent state on the pane.
    private func focusContentFromChromeAction() {
        guard let content = contentView,
            let window = content.window else { return }
        if window.firstResponder !== content {
            window.makeFirstResponder(content)
        }
    }

    /// Populate every chrome action closure so SwiftUI buttons in the
    /// overlay route into existing VC intents + VM methods. Called once
    /// from `viewDidLoad`; the closures hold weak references so VC
    /// teardown doesn't strand them. Every closure runs
    /// `focusContentFromChromeAction()` first: SwiftUI Button hits
    /// resolve to the Button's internal NSView, never reaching the
    /// drag wrapper's mouseDown, so without this any chrome-button
    /// click would leave the pane unfocused.
    private func wireChromeActions() {
        chromeViewModel.onHardwareButton = { [weak self] button in
            self?.focusContentFromChromeAction()
            self?.viewModel.pressButton(button)
        }
        chromeViewModel.onRotateLeft = { [weak self] in
            self?.focusContentFromChromeAction()
            self?.viewModel.rotateLeft()
        }
        chromeViewModel.onRotateRight = { [weak self] in
            self?.focusContentFromChromeAction()
            self?.viewModel.rotateRight()
        }
        chromeViewModel.onCrownUp = { [weak self] in
            self?.focusContentFromChromeAction()
            self?.viewModel.crown(delta: -1)
        }
        chromeViewModel.onCrownDown = { [weak self] in
            self?.focusContentFromChromeAction()
            self?.viewModel.crown(delta: +1)
        }
        chromeViewModel.onScreenshot = { [weak self] in
            self?.focusContentFromChromeAction()
            self?.onScreenshot?()
        }
        chromeViewModel.onRecordToggle = { [weak self] in
            guard let self else { return }
            self.focusContentFromChromeAction()
            if self.recordingProcess == nil {
                self.onRecordStart?()
            } else {
                self.onRecordStop?()
            }
        }
        chromeViewModel.onAxInspectorToggle = { [weak self] in
            self?.focusContentFromChromeAction()
            self?.toggleAxInspector()
        }
        chromeViewModel.onSizePresetSelected = { [weak self] preset in
            self?.focusContentFromChromeAction()
            self?.applySizePreset(preset)
        }
        // ⋯ button reuses the same right-click NSMenu the sim content
        // view exposes, so there's no duplicate menu definition. Positions the
        // popup near the trailing edge of the chrome strip so the
        // menu lands beneath the visible button rather than at the
        // top-left of the pane.
        chromeViewModel.onOpenContextMenu = { [weak self] in
            guard let self,
                let host = self.chromeHostView else { return }
            self.focusContentFromChromeAction()
            let menu = makeSimulatorPaneContextMenu()
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: host.bounds.maxX - 12, y: 0),
                in: host
            )
        }
    }

    /// Tear the daemon pane down and stop consuming events. Forwarded to
    /// the VM; awaited so the quit/teardown paths can guarantee the RPC
    /// completes before the GUI exits. Idempotent.
    func close(mode: PaneCloseMode = .detach) async {
        await viewModel.close(mode: mode)
    }

    /// Try to apply the pending Point Accurate auto-fit immediately
    /// if it can land (window mounted, dims known). Used by the
    /// layout controller for the drag-rearrange case, where an already-
    /// rendering sim's observed VM state doesn't change when it
    /// moves to a new split, so `render()` doesn't re-fire and the
    /// flag would otherwise sit indefinitely. The fresh-attach path
    /// still relies on `render()` because pixel dims arrive later.
    func tryAutoFitNow() {
        let width = chromeViewModel.devicePixelWidth ?? 0
        let height = chromeViewModel.devicePixelHeight ?? 0
        guard pendingAutoFit, width > 0, height > 0, view.window != nil else { return }
        pendingAutoFit = false
        applySizePreset(lastAppliedPreset)
    }

    // MARK: - SimulatorInputDelegate → VM intents

    func simulatorPaneDidTap(at point: CGPoint) {
        viewModel.tap(at: point)
    }

    func simulatorPaneDidTouch(at point: CGPoint, phase: TouchPhase, isEdgeGesture: Bool) {
        viewModel.touch(at: point, phase: phase, isEdgeGesture: isEdgeGesture)
    }

    func simulatorPaneDidSwipe(from start: CGPoint, to end: CGPoint, durationMs: Int) {
        viewModel.swipe(from: start, to: end, durationMs: durationMs)
    }

    func simulatorPaneDidPinch(
        fromF1: CGPoint,
        fromF2: CGPoint,
        toF1: CGPoint,
        toF2: CGPoint,
        durationMs: Int
    ) {
        viewModel.pinch(
            fromF1: fromF1,
            fromF2: fromF2,
            toF1: toF1,
            toF2: toF2,
            durationMs: durationMs
        )
    }

    func simulatorPaneDidMultitouch(
        phase: TouchPhase,
        finger1: CGPoint,
        finger2: CGPoint
    ) {
        viewModel.multitouch(phase: phase, finger1: finger1, finger2: finger2)
    }

    func simulatorPaneKeyDown(keyCode: UInt16) {
        viewModel.keyDown(keyCode: keyCode)
    }

    func simulatorPaneKeyUp(keyCode: UInt16) {
        viewModel.keyUp(keyCode: keyCode)
    }

    func simulatorPaneDidCrown(delta: Double) {
        // Family gate: the Digital Crown only exists on watchOS, so
        // bare scrolls over a phone / pad / tv sim are silently
        // dropped. The content view has already consumed the event,
        // so there's no "scroll on a phone sim moves the window"
        // surprise. The watch crown is the only bare-scroll
        // consumer; a prefs key could later map scroll to something
        // else per family (e.g. phone scroll = simulated swipe).
        guard DeviceFamily(wire: family) == .watch else { return }
        viewModel.crown(delta: delta)
    }

    // MARK: - Render

    /// Re-runs whenever the VM's observed state changes. Reads every
    /// observed property every pass (the observe() tracking contract:
    /// Observation only tracks reads that happened on the most recent
    /// pass, so an early return stops observing the skipped fields).
    /// Announces deduped state transitions to the owner.
    private func render() {
        let state = viewModel.state
        let lease = viewModel.currentSurface
        let orientation = viewModel.currentOrientation
        contentView?.applyFrame(lease: lease, traceSequence: viewModel.currentSurfaceSequence)
        contentView?.setOrientation(orientation)
        refreshOverlay(for: state)
        // Push the bezel inputs every render(). The wrapper's
        // `BezelContext.didSet` gates layout to actual changes, so
        // this is cheap when nothing moved.
        if let wrapper = wrapperView, let content = contentView {
            wrapper.bezelContext = SimulatorPaneWrapperView.BezelContext(
                family: DeviceFamily(wire: viewModel.family),
                surfaceSize: content.surfaceSize,
                orientation: viewModel.currentOrientation
            )
        }
        // Mirror VM state + record status into the chrome's view
        // model so the SwiftUI badge + record button reflect them.
        // Observation will re-render the SwiftUI body when these
        // change; assigning identical values is a no-op for tracking.
        chromeViewModel.simState = state
        chromeViewModel.recordingActive = recordingProcess != nil
        // Pixel dimensions come from the live IOSurface. The daemon's attach
        // response may have shipped nil pixelWidth/pixelHeight when the
        // renderable wasn't bound yet (fast attach against a still-
        // booting sim). Reading from the surface itself once it lands
        // keeps the size-preset math accurate without needing a wire
        // round-trip; otherwise the chrome's preset menu would
        // permanently no-op for those attach-then-render flows.
        // Re-runs on every observed change because `currentSurface` is
        // an observed property; the assignment is a no-op-for-
        // tracking once the values match.
        if let surface = lease?.surface {
            chromeViewModel.devicePixelWidth = Int(IOSurfaceGetWidth(surface))
            chromeViewModel.devicePixelHeight = Int(IOSurfaceGetHeight(surface))
        }
        // Auto-fit on attach / drag-rearrange. Fires once: the
        // layout controller marks `pendingAutoFit` after a tree
        // change, and the next render() with non-zero pixel dims
        // applies Point Accurate sizing. Subsequent reconciles can
        // re-arm the flag; user divider drags don't.
        if pendingAutoFit,
            (chromeViewModel.devicePixelWidth ?? 0) > 0,
            (chromeViewModel.devicePixelHeight ?? 0) > 0,
            view.window != nil {
            pendingAutoFit = false
            applySizePreset(lastAppliedPreset)
        }
        if state != lastNotifiedState {
            lastNotifiedState = state
            onStateChange?(state)
        }
    }

    private func refreshOverlay(for state: SimulatorPaneState) {
        switch state {
        case .booting:
            overlay.isHidden = false
            overlay.stringValue = "Booting \(displayName)…"
            shutdownButtons.isHidden = true

        case .rendering:
            overlay.isHidden = true
            shutdownButtons.isHidden = true

        case .shutdown:
            overlay.isHidden = false
            // A device pane reaches this when its mirror stopped, not when
            // anything shut down, and a watch is already waiting to re-mirror
            // it. Reboot is a simulator action with no device wiring, so the
            // device overlay offers Close Pane alone rather than a button
            // that would do nothing.
            overlay.stringValue = isPhysicalDevice
                ? "\(displayName) stopped mirroring. Reconnecting…"
                : "Simulator shut down."
            rebootButton.isHidden = isPhysicalDevice
            shutdownButtons.isHidden = false

        case let .failed(message):
            overlay.isHidden = false
            overlay.stringValue = "Failed: \(message)"
            shutdownButtons.isHidden = true
        }
        // Scrim follows the overlay: dim the (possibly frozen) frame
        // whenever a message is shown, leave it clear while rendering.
        dimView.isHidden = overlay.isHidden
    }

    @objc
    private func closePaneClicked(_ sender: Any?) {
        onClose?()
    }

    @objc
    private func rebootClicked(_ sender: Any?) {
        onReboot?()
    }

    // MARK: - Device menu @objc selectors
    //
    // Main-menu items target these selectors with `nil` target so the
    // responder chain finds them when a sim pane is first responder.
    // `PaneLayoutViewController` declares mirroring fallbacks so the
    // actions still work when a terminal pane is focused; the chain
    // there resolves to the tab's first sim pane.

    @objc
    func pressHardwareHome(_ sender: Any?) {
        viewModel.pressButton(.home)
    }

    /// Open the iOS App Switcher: a swipe-up-from-the-bottom-edge with
    /// a dwell (no hardware button maps to it). Delegated to the view
    /// model so the gesture is composed orientation-aware.
    @objc
    func invokeAppSwitcher(_ sender: Any?) {
        viewModel.appSwitcher()
    }

    @objc
    func pressHardwareLock(_ sender: Any?) {
        viewModel.pressButton(.lock)
    }

    @objc
    func pressHardwareSide(_ sender: Any?) {
        viewModel.pressButton(.side)
    }

    @objc
    func pressHardwareSiri(_ sender: Any?) {
        viewModel.pressButton(.siri)
    }

    @objc
    func pressHardwareApplePay(_ sender: Any?) {
        viewModel.pressButton(.applePay)
    }

    /// Watch-only Digital Crown press. The crown press is the
    /// home-equivalent on watchOS; the rotary input is a separate
    /// channel (`rotateCrownUp` / `rotateCrownDown`). Selector is
    /// validated `enabled` only when the targeted sim is a watch
    /// (see `validateUserInterfaceItem`).
    @objc
    func pressDigitalCrown(_ sender: Any?) {
        viewModel.pressButton(.digitalCrown)
    }

    /// Watch-only one-detent Digital Crown rotation. "Up" scrolls
    /// the watch UI's content upward (toward the top of a list).
    /// Daemon convention is positive = forward/down, so up is
    /// negative.
    @objc
    func rotateCrownUp(_ sender: Any?) {
        viewModel.crown(delta: -1)
    }

    /// Watch-only one-detent Digital Crown rotation. "Down" scrolls
    /// the watch UI's content downward (advances through a list).
    @objc
    func rotateCrownDown(_ sender: Any?) {
        viewModel.crown(delta: +1)
    }

    @objc
    func rotateDeviceLeft(_ sender: Any?) {
        viewModel.rotateLeft()
    }

    @objc
    func rotateDeviceRight(_ sender: Any?) {
        viewModel.rotateRight()
    }

    /// Device ▸ Location: apply the `SimulatedLocation` the chosen row
    /// carries in its `representedObject`.
    ///
    /// Also the *parent* "Location" item's action, which AppKit never
    /// sends because that item owns a submenu. It is attached there so
    /// `validateUserInterfaceItem` can grey the whole submenu out on a
    /// pane whose device has no location support. The
    /// `representedObject` guard below makes that harmless.
    @objc
    func applySimulatedLocation(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
            let location = item.representedObject as? SimulatedLocation else { return }
        locationViewModel.apply(location)
    }

    /// Device ▸ Location ▸ Custom Coordinates…: type a position by hand.
    ///
    /// Applying also attempts to save the point. `apply` refreshes
    /// `savedLocations` after the set attempt completes, so reopening
    /// the menu before then still draws the previous snapshot.
    @objc
    func showCustomCoordinates(_ sender: Any?) {
        let sheet = CustomCoordinatesSheet(
            onSubmit: { [weak self] location, label in
                self?.dismissCustomCoordinates()
                self?.locationViewModel.apply(location, label: label)
            },
            onCancel: { [weak self] in self?.dismissCustomCoordinates() }
        )
        presentAsSheet(NSHostingController(rootView: sheet))
    }

    /// Device ▸ Location ▸ Use My Location: snapshot this Mac's position
    /// and apply it.
    ///
    /// Captures the view model rather than reaching through `self` after
    /// the await, so a pane closed while the fix is being taken is not
    /// held open by it. An unanswered permission prompt can keep the
    /// task alive for about a minute, which is ample time to close a
    /// tab.
    ///
    /// Which is why this controller's own existence is the fence the
    /// view model re-checks before sending anything. A pane id outlives
    /// the tab that closed it (an orphaned sim keeps its record and can
    /// be adopted by another session), and the GUI's connection is
    /// authorized for any live pane, so a fix answered after this pane
    /// went away would otherwise land on somebody else's device.
    @objc
    func useMyLocation(_ sender: Any?) {
        let viewModel = locationViewModel
        Task { @MainActor [weak self] in
            let alert = await viewModel.useMyLocation(isPaneLive: { self != nil })
            guard let alert else { return }
            self?.presentLocationAlert(alert)
        }
    }

    /// Device ▸ Location ▸ a saved `.gpx` row: walk the device along it.
    ///
    /// Same shape as `useMyLocation`, and for the same reasons: reading
    /// and parsing a route suspends, the view model owns the pane-liveness
    /// fence, and a failure alerts because the checkmark not moving is
    /// otherwise indistinguishable from a row that does nothing.
    @objc
    func applyRouteFile(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
            let path = item.representedObject as? String else { return }
        let viewModel = locationViewModel
        Task { @MainActor [weak self] in
            let alert = await viewModel.applyRoute(path: path, isPaneLive: { self != nil })
            guard let alert else { return }
            self?.presentLocationAlert(alert)
        }
    }

    /// Report a Location-menu failure the menu itself can't show.
    /// `NSAlert` + `runModal` matches the other alerts this controller
    /// raises (Erase, Shut Down); the settings button appears only for
    /// the outcomes the user can actually change, which the decision
    /// namespaces (`UseMyLocationDecision`, `RouteFileDecision`) decide.
    private func presentLocationAlert(_ content: LocationAlert) {
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.body
        alert.alertStyle = .warning
        guard let settingsURL = content.settingsURL else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        alert.addButton(withTitle: UseMyLocationDecision.settingsButtonTitle)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    /// Dismiss the sheet controller explicitly. `dismiss(nil)` selects
    /// `dismissController:` and targets the receiver; the presenter must
    /// call `dismiss(_ viewController:)`. The type lookup avoids closing
    /// another sheet.
    private func dismissCustomCoordinates() {
        let sheet = presentedViewControllers?.first {
            $0 is NSHostingController<CustomCoordinatesSheet>
        }
        guard let sheet else { return }
        dismiss(sheet)
    }

    @objc
    func rebootDevice(_ sender: Any?) {
        onLiveReboot?()
    }

    @objc
    func eraseAllContent(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Erase \(displayName)?"
        alert.informativeText = "This will erase all content and "
            + "settings on \(displayName), returning it to factory "
            + "state. The simulator will reboot."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            onEraseContent?()
        }
    }

    @objc
    func screenshotPane(_ sender: Any?) {
        onScreenshot?()
    }

    @objc
    func recordPane(_ sender: Any?) {
        if recordingProcess == nil {
            onRecordStart?()
        } else {
            onRecordStop?()
        }
    }

    @objc
    func openInSimulatorApp(_ sender: Any?) {
        onOpenInSimulatorApp?()
    }

    @objc
    func shutDownSim(_ sender: Any?) {
        onShutDownSim?()
    }

    @objc
    func revealInFinder(_ sender: Any?) {
        onRevealInFinder?()
    }

    /// Right-click Close Pane. Same effect as the shutdown
    /// overlay's Close Pane button, just available without waiting
    /// for the sim to enter `.shutdown` first.
    @objc
    func closePane(_ sender: Any?) {
        onClose?()
    }

    @objc
    func installApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Install App on \(displayName)"
        panel.message = "Choose a .app bundle to install."
        panel.prompt = "Install"
        // `simctl install` only accepts an unpacked `.app` bundle;
        // restricting the picker to that type avoids letting the
        // user select an `.ipa` and then surfacing a confusing
        // simctl failure alert downstream. An `.ipa` is a Zip with
        // `Payload/<App>.app/` inside, so supporting it would require
        // unpacking before the call and isn't in scope here.
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onInstallApp?(url)
        }
    }

    // MARK: - Size-preset selectors
    //
    // The View menu's ⌃⌘1–⌃⌘4 shortcuts target nil so the responder
    // chain finds these on the focused sim pane. PaneLayoutViewController
    // mirrors them so a focused terminal pane still drives the tab's
    // primary sim. Each selector delegates to `applySizePreset(_:)`
    // which both updates the chromeViewModel selection and asks the
    // owning split to snap the divider.

    @objc
    func applySizePresetPhysical(_ sender: Any?) {
        applySizePreset(.physical)
    }

    @objc
    func applySizePresetPointAccurate(_ sender: Any?) {
        applySizePreset(.pointAccurate)
    }

    @objc
    func applySizePresetPixelAccurate(_ sender: Any?) {
        applySizePreset(.pixelAccurate)
    }

    @objc
    func applySizePresetFitScreen(_ sender: Any?) {
        applySizePreset(.fitScreen)
    }

    /// Apply a size preset to this pane. Stamps the chrome's
    /// `selectedPreset` (so the chrome picker shows a checkmark) and
    /// asks the owning split VC to recompute the divider position.
    /// Callable from the View menu's ⌃⌘1–⌃⌘4 shortcuts and from the
    /// chrome ribbon's Size dropdown. Those are the only two surfaces;
    /// the sim pane's right-click menu carries no size items.
    func applySizePreset(_ preset: SimSizePreset) {
        chromeViewModel.selectedPreset = preset
        // Stick the chosen preset so an auto-fit pass after a tree change
        // (a drag-rearrange, a sibling close) replays it rather than
        // springing back to the family default, and report it up so it
        // also outlives this view controller.
        //
        // Only on a real change, which is what keeps those replays out of
        // nav state: an auto-fit re-applies `lastAppliedPreset` itself. A
        // user picking the preset the pane is already on reports nothing
        // either, and needs to: the default this falls back to is the same
        // function of family that seeded it.
        if preset != lastAppliedPreset {
            lastAppliedPreset = preset
            onSizePresetChange?(preset)
        }
        let device = SimDeviceMetrics(
            pixelWidth: chromeViewModel.devicePixelWidth ?? 0,
            pixelHeight: chromeViewModel.devicePixelHeight ?? 0,
            family: DeviceFamily(wire: viewModel.family)
        )
        // Ask the owning layout controller to size this pane by walking
        // up via `parent`. The split owns divider position
        // (`NSSplitView.setPosition`); the pane just tells it which
        // preset to honor and provides the device metrics.
        var responder: NSResponder? = self
        while let next = responder {
            if let split = next as? PaneLayoutViewController {
                split.applySizePreset(
                    preset,
                    forSimPane: self,
                    device: device,
                    orientation: viewModel.currentOrientation,
                    chromeHeight: Self.chromeHeight(forFamily: viewModel.family)
                )
                return
            }
            responder = next.nextResponder
        }
    }

    // MARK: - AX inspector

    /// Flip the chrome's AX inspector on / off. On enable, install a
    /// mouse-tracking area on the content view so `mouseMoved` fires
    /// even outside first-responder focus; on disable, remove it and
    /// clear any stale label.
    @objc
    func toggleAxInspector(_ sender: Any?) {
        chromeViewModel.axInspectorEnabled.toggle()
        if chromeViewModel.axInspectorEnabled {
            installAxTrackingArea()
            mountAxInspectorPanel()
        } else {
            removeAxTrackingArea()
            chromeViewModel.axInspectorLabel = nil
            axViewModel.label = nil
            unmountAxInspectorPanel()
        }
    }

    /// Slide the AX side panel in on the right edge of the sim pixels.
    /// Sim pixels shrink horizontally by 240pt so the
    /// pane fits both content and panel without growing chrome height.
    /// The animation is a brief eased width transition driven by AppKit.
    private func mountAxInspectorPanel() {
        guard let wrapper = wrapperView,
            let content = contentView,
            let chrome = chromeHostView,
            axPanelHost == nil else { return }
        let panel = NSHostingView(rootView: SimulatorPaneAXInspector(viewModel: axViewModel))
        panel.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(panel)
        let topConstraint = panel.topAnchor.constraint(equalTo: chrome.bottomAnchor)
        let trailingConstraint = panel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        let bottomConstraint = panel.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor)
        // Width is high-priority but not required so panes narrower than
        // 240pt don't trip Auto Layout. The content's nonnegative-width
        // floor takes precedence; the panel just shrinks below ideal.
        let widthConstraint = panel.widthAnchor.constraint(equalToConstant: 240)
        widthConstraint.priority = .defaultHigh
        let panelMinWidth = panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        let contentMinWidth = content.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        let newTrailing = content.trailingAnchor.constraint(equalTo: panel.leadingAnchor)
        contentTrailingToWrapperEdge?.isActive = false
        NSLayoutConstraint.activate([
            topConstraint,
            trailingConstraint,
            bottomConstraint,
            widthConstraint,
            panelMinWidth,
            contentMinWidth,
            newTrailing
        ])
        axPanelHost = panel
        axPanelTopConstraint = topConstraint
        axPanelTrailingConstraint = trailingConstraint
        axPanelBottomConstraint = bottomConstraint
        axPanelWidthConstraint = widthConstraint
        contentTrailingToAxPanel = newTrailing
        contentMinWidthConstraint = contentMinWidth
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            wrapper.animator().layoutSubtreeIfNeeded()
        }
    }

    /// Remove the AX side panel and restore sim pixels to full width.
    private func unmountAxInspectorPanel() {
        guard let wrapper = wrapperView,
            let panel = axPanelHost else { return }
        NSLayoutConstraint.deactivate([
            axPanelTopConstraint,
            axPanelTrailingConstraint,
            axPanelBottomConstraint,
            axPanelWidthConstraint,
            contentTrailingToAxPanel,
            contentMinWidthConstraint
        ].compactMap(\.self))
        panel.removeFromSuperview()
        axPanelHost = nil
        axPanelTopConstraint = nil
        axPanelTrailingConstraint = nil
        axPanelBottomConstraint = nil
        axPanelWidthConstraint = nil
        contentTrailingToAxPanel = nil
        contentMinWidthConstraint = nil
        contentTrailingToWrapperEdge?.isActive = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            wrapper.animator().layoutSubtreeIfNeeded()
        }
    }

    /// Closure-target wrapper for the chrome button (which doesn't pass
    /// a `sender:`). Keeps the @objc selector clean for the menu
    /// dispatch path while letting SwiftUI's `() -> Void` closure call
    /// through.
    private func toggleAxInspector() {
        toggleAxInspector(nil)
    }

    private func installAxTrackingArea() {
        guard let content = contentView, axTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: content.bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        content.addTrackingArea(area)
        axTrackingArea = area
    }

    private func removeAxTrackingArea() {
        if let area = axTrackingArea, let content = contentView {
            content.removeTrackingArea(area)
        }
        axTrackingArea = nil
    }

    /// AppKit forwards `mouseMoved` to the tracking area's `owner`
    /// (this VC). Throttle to one in-flight request at a time + at
    /// most one per 150ms; the daemon's AX call is cheap but a fast
    /// mouse over a wide pane would still flood the wire.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard chromeViewModel.axInspectorEnabled,
            let content = contentView,
            !axQueryInFlight else { return }
        let now = Date()
        if let last = lastAxQueryTime, now.timeIntervalSince(last) < 0.15 { return }
        lastAxQueryTime = now
        let viewPoint = content.convert(event.locationInWindow, from: nil)
        guard content.bounds.contains(viewPoint) else { return }
        // Reuse the gesture-math normalizer so the AX inspector lands
        // exactly where a tap would, using the same aspect-fit
        // letterbox math and orientation adjustment. surfaceSize zero means the
        // renderable isn't bound yet; bail rather than send a fake
        // (0, 0) point.
        guard let normalized = SimGestureMath.normalizedPoint(
            viewPoint: viewPoint,
            viewSize: content.bounds.size,
            surfaceSize: content.surfaceSize,
            orientation: viewModel.currentOrientation,
            displayInset: content.displayInset
        ) else { return }
        axQueryInFlight = true
        let paneId = viewModel.paneId
        let client = axDaemonClient
        Task { @MainActor [weak self] in
            defer { self?.axQueryInFlight = false }
            let summary = try? await client.paneAxPoint(
                paneId: paneId,
                x: normalized.x,
                y: normalized.y
            )
            self?.chromeViewModel.axInspectorLabel = summary
            // Mirror into the AX side panel's view model so the
            // SwiftUI inspector re-renders on every label update.
            self?.axViewModel.label = summary
        }
    }

    @objc
    func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        // Title-toggle the Record menu slot so the same item reads
        // either start or stop based on this pane's current state.
        // AppKit re-validates on every menu open, so the label tracks
        // the live state without explicit invalidation hooks. For
        // every other Device-menu selector we respond to, the
        // implicit answer is "yes, enabled": being in the responder
        // chain for the action is the entire condition.
        if let menuItem = item as? NSMenuItem,
            menuItem.action == #selector(recordPane(_:)) {
            menuItem.title = recordingProcess == nil
                ? "Record Screen"
                : "Stop Recording"
        }
        // Gate every device-control selector on this pane's
        // capabilities + kind through the shared affordance rule, so a
        // physical-device pane disables the simulator-only actions
        // (Erase / Shut Down / Open in Simulator / Reveal / Apple Pay,
        // and the not-yet-wired Reboot / Screenshot / Record / Install)
        // and the controls it can't do (crown / AX), while keeping the
        // ones it can (buttons / rotate). A sim reports the full set so
        // the gate is a no-op for it. Ungated selectors (size presets,
        // Close Pane) fall through to "enabled".
        if let action = item.action,
            let affordance = PaneControlAffordance.forSelector(action) {
            return affordance.isEnabled(
                capabilities: capabilities,
                isPhysicalDevice: isPhysicalDevice,
                family: DeviceFamily(wire: family)
            )
        }
        return true
    }
}

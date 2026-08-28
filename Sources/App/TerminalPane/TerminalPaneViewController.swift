// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import GhosttyKitResources
import LibghosttyBridge
import TerminalSurface

/// Hosts one libghostty surface in an AppKit VC.
///
/// The embed recipe is the authoritative one from
/// `Sources/LibghosttyHarness/main.swift`: own a clean container view,
/// fill-constrain `surface.view`, `attach(command:)`, make the host
/// first responder. libghostty owns the PTY in-process; the shell is
/// spawned from a `TerminalCommand.loginShell` the GUI builds from
/// daemon-issued credentials plus app-owned shell settings.
///
/// Resources-dir resolver: env override → the bundled
/// `Contents/Resources/ghostty` tree → `GhosttyKitResources.
/// directoryURL` (safe only unbundled: it fatalErrors if Bundle.module
/// can't resolve, which is the case inside a signed .app).
@MainActor
final class TerminalPaneViewController: NSViewController, TerminalSurfaceDelegate {
    /// Constant chrome height; the libghostty scroll wrapper's top
    /// inset accounts for it.
    /// Chrome strip total height. The visible band is the top 8pt
    /// (with the ⋯ on hover); the bottom 6pt is transparent overlap
    /// with the terminal surface: extra grab area for dragging the
    /// pane without making the visible chrome any taller.
    static let chromeHeight: CGFloat = 14
    static let chromeVisibleHeight: CGFloat = 8

    /// Stable identity for this terminal pane inside its tab. The
    /// split VC uses this to remove the right item on close, and the
    /// reconciler keys its `terminalVCByID` lookup table off it.
    let terminalID: TerminalPaneID
    /// Tab id this terminal belongs to: used as the drag-payload tab
    /// match-check when the chrome strip initiates a pane drag.
    /// Settable so the parent (`TabContentViewController`) can wire
    /// it after construction; nil disables drag.
    var tabID: TabID? {
        didSet { chromeHostView?.tabID = tabID }
    }
    /// Observable chrome state: title + close / context-menu hooks.
    let chromeViewModel = TerminalPaneChromeViewModel()
    private var chromeHostView: PaneChromeDragHostView<TerminalPaneChromeView>?
    private var surface: GhosttyTerminalSurface?
    /// Tail of the paced-typing animation chain for
    /// `sendInput(_:typeDelayMillis:)`. New paced calls chain after this
    /// so a rapid presenter can't interleave two commands' characters
    /// into the surface.
    private var typingTask: Task<Void, Never>?
    /// Bumped by `requestClose` to stop *every* queued paced-typing task
    /// at once. Each task captures the generation at enqueue and bails
    /// the moment it no longer matches. Cancelling only the chain's
    /// tail (`typingTask`) wouldn't reach an earlier task still typing,
    /// since cancellation doesn't propagate across `await previous`.
    private var typingGeneration = 0
    /// Paced-typing tasks enqueued and not yet finished. `typingTask`
    /// can't answer "is one in flight?" on its own: normal completion
    /// never clears it, so after the first paced call it stays non-nil
    /// forever and every later call would think it was queued behind
    /// something. Tracking the count keeps the leading inter-command
    /// delay to calls that genuinely chain.
    private var pendingTypingTasks = 0
    private var scrollWrapper: SurfaceScrollView?
    /// Whether `viewDidAppear` has already claimed first responder for
    /// this pane. See the gate on that method for what it protects.
    private var hasClaimedInitialFocus = false
    private let environment: [String: String]
    /// One-shot startup hint from `deviceterm tab open --cwd <path>` /
    /// `pane open --terminal --cwd <path>`. Threads through to
    /// libghostty's `config.working_directory`; nil falls back to the
    /// GUI process's CWD (libghostty's default).
    private let cwd: String?
    /// One-shot startup command typed into the shell after attach.
    /// Joined with spaces and a trailing `\n` so the shell executes
    /// it once and leaves the user at an interactive prompt: same
    /// shape as if the user had typed it themselves. Maps to
    /// libghostty's `config.initial_input`.
    private let command: [String]?

    /// Fired when the shell exits (libghostty child-exited). The
    /// container decides what closing means (close tab / window).
    var onExit: ((Int32?) -> Void)?
    /// Fired on OSC 0/2 title changes so the tab/window can relabel.
    var onTitleChange: ((String) -> Void)?
    /// Fired on OSC 7 working-directory changes so the tab can derive a
    /// CWD-basename label.
    var onWorkingDirectoryChange: ((String) -> Void)?
    /// Latest OSC 0/2 title and OSC 7 path this terminal emitted, retained
    /// per terminal because the tab shows only its *primary* terminal's
    /// label. When the primary closes and another terminal is promoted, the
    /// tab reseeds from the new primary's values; without them the promoted
    /// session would inherit the departed terminal's activity string.
    private(set) var lastOSCTitle: String?
    private(set) var lastWorkingDirectory: String?
    /// Fired when libghostty emits a SCROLLBAR action (scrollback
    /// extended, viewport moved, layout changed). The
    /// `SurfaceScrollView` wrapper latches onto this to drive overlay
    /// scroller geometry. The latest state is also cached so a
    /// late-installing scroll wrapper can read it on bring-up
    /// without waiting for the next emission.
    var onScrollbarUpdate: ((ScrollbarState) -> Void)?
    private(set) var latestScrollbarState: ScrollbarState = .empty

    /// Fired when the user picks "Close Pane" from the right-click
    /// menu. Separate from `onExit` (shell death) so the container
    /// can route to the right outcome: the same handler the shell-
    /// exit path uses on a multi-terminal tab (drop this terminal),
    /// and the tab-close path when this is the last terminal.
    var onClosePaneRequested: (() -> Void)?

    /// Fired when the user picks "Open in New Tab" from the right-
    /// click menu. The container resolves to `Route.openTab` carrying
    /// the source tab's latest cwd so the new tab opens in the same
    /// directory.
    var onOpenInNewTabRequested: (() -> Void)?

    /// Fired for "Split Right" / "Split Down". The container splits
    /// **just this pane** by dispatching `Route.openTerminalPane` with
    /// this pane as the anchor and the chosen axis, so splitting the
    /// left pane leaves the rest of the tree untouched (a nested
    /// sub-split when the axis differs from the anchor's parent).
    /// `isVertical = true` produces a vertical divider (panes
    /// side-by-side, "Split Right"); `false` produces a horizontal
    /// divider (panes stacked, "Split Down").
    var onSplitRequested: ((_ isVertical: Bool) -> Void)?

    /// Fires when libghostty's surface becomes the window's first
    /// responder (false → true edge from the wrapper's responder-
    /// chain hook). The container forwards this to the tab
    /// controller so `TabState.lastFocusedTerminal` follows the
    /// user's actual typing target: the spawning-terminal heuristic
    /// for sim placement keys off that field.
    var onFocusGained: (() -> Void)?

    /// Binds this terminal's kernel identity to its session on the daemon:
    /// the provenance "terminal" arm that lets an in-tab CLI process
    /// authenticate as this pane's session. The container sets it to call
    /// `daemon.bindTerminal`, returning `true` on success. The VC owns the
    /// retry loop (it holds the surface, so it can re-read a FRESH identity
    /// each attempt: a stale foreground pid, one that exited, would make every
    /// daemon probe fail). Without a bind, in-tab `deviceterm` calls get
    /// `notReady` until their retries expire.
    var performBind: ((_ sessionId: String, _ identity: TerminalIdentity) async -> Bool)?
    /// The bounded poll+bind that waits for the shell's pid after `attach`.
    /// Cancelled on teardown so it doesn't outlive the surface.
    private var terminalBindTask: Task<Void, Never>?
    /// Set on `requestClose` so a late reconnect-driven rebind (or an
    /// in-flight poll) doesn't schedule work against a torn-down pane.
    private var terminalBindTornDown = false

    init(
        terminalID: TerminalPaneID,
        environment: [String: String],
        cwd: String? = nil,
        command: [String]? = nil
    ) {
        self.terminalID = terminalID
        self.environment = environment
        self.cwd = cwd
        self.command = command
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private static func resourcesDirectory() -> URL? {
        if let override = ProcessInfo.processInfo
            .environment["DEVICETERM_LIBGHOSTTY_RESOURCES"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // Bundled: make-app-bundle.sh drops the tree here. Checked
        // first because `GhosttyKitResources.directoryURL` is
        // non-optional and fatalErrors if Bundle.module can't resolve
        // it (its layout differs inside a signed .app).
        if let res = Bundle.main.resourceURL?
            .appendingPathComponent("ghostty"),
            FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        // Unbundled dev (`swift run App`): the SwiftPM resource bundle
        // sits next to the binary, so this resolves safely.
        return GhosttyKitResources.directoryURL
    }

    override func loadView() {
        // `TerminalPaneWrapperView` paints the focus border around the
        // entire pane (chrome strip + libghostty surface). It tracks
        // window first-responder changes via NSWindow.didUpdate so the
        // border toggles when libghostty's surface gains / loses focus.
        // libghostty's surface is a foreign-module view we don't
        // subclass, so the polling shape is the portable hook.
        view = TerminalPaneWrapperView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let surface = GhosttyTerminalSurface(
            resourcesDirectory: Self.resourcesDirectory(),
            loadUserConfig: !GhosttyConfigOverride.ignoresUserConfig()
        )
        surface.delegate = self
        self.surface = surface
        // Attach the right-click menu directly to the libghostty
        // surface view: that's the view AppKit hit-tests at right-
        // click time, and its `menu(for:)` override promotes itself
        // to first responder before AppKit reads the menu. The menu
        // items dispatch nil-targeted so AppKit walks the responder
        // chain and lands on this VC.
        surface.view.menu = makeTerminalPaneContextMenu()

        // Wrap the libghostty surface view in `SurfaceScrollView` so
        // the host renders a native overlay scrollbar against
        // libghostty's scrollback state. The surface remains the
        // first-responder target: `focus()` and `viewDidAppear` still
        // target `surface.view` directly so keyDown / NSTextInputClient
        // flow into libghostty as before. The cellHeight +
        // scrollToRow closures bridge to the engine; the SCROLLBAR
        // delegate callback feeds the wrapper's `updateScrollbar(_:)`
        // further below.
        let scrollWrapper = SurfaceScrollView(
            surfaceView: surface.view,
            cellHeightProvider: { [weak surface] in
                surface?.cellSize.height ?? 0
            },
            scrollToRow: { [weak surface] row in
                surface?.scroll(toRow: row)
            }
        )
        self.scrollWrapper = scrollWrapper
        scrollWrapper.translatesAutoresizingMaskIntoConstraints = false

        // Mount the translucent chrome strip above the
        // libghostty surface. The strip hosts the SwiftUI chrome
        // view inside `PaneChromeDragHostView`, which catches
        // mouseDown / mouseDragged to start a pane drag carrying the
        // terminal's slot identity.
        //
        // The minimal terminal chrome only carries the ⋯ menu opener;
        // title/close were removed (tab strip carries title; close
        // lives in the ⋯ menu). `onClosePaneRequested` is still routed
        // from the right-click "Close Pane" item; see
        // `makeTerminalPaneContextMenu`.
        chromeViewModel.onOpenContextMenu = { [weak self] in
            guard let self,
                let host = self.chromeHostView else { return }
            let menu = makeTerminalPaneContextMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: host.bounds.midX, y: 0), in: host)
        }
        let chromeHost = PaneChromeDragHostView(
            rootView: TerminalPaneChromeView(viewModel: chromeViewModel)
        )
        chromeHost.tabID = tabID
        chromeHost.slot = .terminal(terminalID)
        chromeHost.snapshotSource = view
        // A click on the chrome strip should focus the libghostty
        // surface: same first-responder target the responder-chain
        // walk on `TerminalPaneWrapperView` is watching for. Without
        // this, clicking the chrome would never light up the focus
        // border on a multi-pane tab.
        chromeHost.focusReceiver = surface.view
        // The wrapper reports both edges; only the arrival interests
        // the tab controller, which stamps `TabState.lastFocusedTerminal`
        // from it.
        (view as? TerminalPaneWrapperView)?.onFocusChange = { [weak self] focused in
            guard focused else { return }
            self?.onFocusGained?()
        }
        // Anything that focuses the pane by its root view has to reach
        // the surface, not the wrapper. That covers the layout
        // controller's `restoreFocus`, and so every pane-navigation and
        // rearrange shortcut. The wrapper forwards to whatever is named
        // here.
        (view as? TerminalPaneWrapperView)?.inputTarget = surface.view
        chromeHost.translatesAutoresizingMaskIntoConstraints = false
        // scrollWrapper added FIRST so chromeHost sits ON TOP of it in
        // z-order: chrome's bottom 6pt overlap with terminal then
        // catches clicks for the pane-drag grab area.
        view.addSubview(scrollWrapper)
        view.addSubview(chromeHost)
        self.chromeHostView = chromeHost
        NSLayoutConstraint.activate(
            [
            chromeHost.topAnchor.constraint(equalTo: view.topAnchor),
            chromeHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeHost.heightAnchor.constraint(equalToConstant: Self.chromeHeight),
            // Terminal surface starts at the BOTTOM of the visible chrome
            // (chromeHost.top + 8), not below chromeHost, so the chrome's
            // bottom 6pt overlaps the terminal as an extra grab area
            // without making the visible chrome any taller. chromeHost is
            // on top in z-order (added first) so clicks in the overlap
            // region drag the pane.
            scrollWrapper.topAnchor.constraint(
                equalTo: chromeHost.topAnchor,
                constant: Self.chromeVisibleHeight
            ),
            scrollWrapper.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollWrapper.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollWrapper.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ]
            )

        do {
            // libghostty types `initial_input` into the shell after
            // attach, so wrap the user's `--cmd '<cmd>'` with a
            // trailing newline to drive execution. Joining with
            // spaces handles a programmatic caller that splits its
            // command into argv-shaped tokens (CLI sends a single
            // string in a length-1 array; either shape lands the
            // same bytes).
            let initialInput = command.flatMap { tokens -> String? in
                guard !tokens.isEmpty else { return nil }
                return tokens.joined(separator: " ") + "\n"
            }
            try surface.attach(
                command: .loginShell(
                    environment: shellEnvironmentWithTerminfo(),
                    workingDirectory: cwd,
                    initialInput: initialInput
                )
            )
        } catch {
            FileHandle.standardError.write(
                Data("deviceterm: terminal attach failed: \(error)\n".utf8)
            )
            onExit?(nil)
            return
        }
        scheduleTerminalBind()
    }

    /// Claims first responder once, the first time this pane reaches a
    /// window, so a brand-new pane starts focused: a new tab, or the
    /// terminal a split just created.
    ///
    /// Every later appearance is a layout rebuild re-adding the same
    /// view. `PaneLayoutViewController.reconcile` tears the whole hierarchy
    /// down and back up on any tree change, and the appearance callbacks
    /// land after it has already restored the previously-focused pane.
    /// Re-claiming there hands focus to whichever pane comes last in
    /// display order, so a rearrange or a close lands the user on an
    /// unrelated pane. Tab switching does not rely on this: it calls
    /// `focus()` on the tab's primary terminal directly.
    override func viewDidAppear() {
        super.viewDidAppear()
        // The flag stays false until the surface view exists, so a pane
        // whose attach is still running gets its turn on a later
        // appearance rather than spending it here.
        guard !hasClaimedInitialFocus, let host = surface?.view else { return }
        hasClaimedInitialFocus = true
        view.window?.makeFirstResponder(host)
    }

    /// After `attach` (and on every reconnect), poll for the shell's foreground
    /// identity and bind it. Each attempt re-reads a FRESH `terminalIdentity()`
    /// (never a cached one) so a pid that changed or exited between attempts
    /// doesn't wedge every retry against a dead process. Bounded; a permanent
    /// failure is logged rather than silently abandoned. A prior scheduled bind
    /// is cancelled first, so a reconnect always polls fresh.
    private func scheduleTerminalBind() {
        guard !terminalBindTornDown else { return }
        guard let sessionId = environment[DeviceTermEnv.session], !sessionId.isEmpty else { return }
        terminalBindTask?.cancel()
        terminalBindTask = Task { @MainActor [weak self] in
            for _ in 0..<50 {  // ~5s at 100ms; the shell spawns well within this
                guard let self, !self.terminalBindTornDown, !Task.isCancelled else { return }
                guard let identity = self.surface?.terminalIdentity() else {
                    try? await Task.sleep(nanoseconds: 100_000_000)  // shell still spawning
                    continue
                }
                if await self.performBind?(sessionId, identity) == true { return }
                try? await Task.sleep(nanoseconds: 100_000_000)  // probe failed; re-read fresh
            }
            FileHandle.standardError.write(
                Data("deviceterm: terminal bind gave up after retries; in-tab CLI may fail\n".utf8)
            )
        }
    }

    /// Re-bind after a reconnect / daemon restart dropped the anchor. Re-polls a
    /// FRESH identity (never replays a stale one); no-op once torn down.
    func rebindTerminal() {
        guard !terminalBindTornDown else { return }
        scheduleTerminalBind()
    }

    /// The shell env plus an explicit `TERMINFO` pointing at the
    /// libghostty resources `terminfo` tree. libghostty sets
    /// `TERM=xterm-ghostty` but does not reliably propagate a
    /// `TERMINFO` the spawned shell can load, and `xterm-ghostty` is
    /// not in the macOS system terminfo database, so without this the
    /// shell's line editor (ZLE et al.) can't resolve the cursor-
    /// movement capabilities it needs and redraws garble (the prompt,
    /// emitted as raw ANSI, still looks fine; only line editing
    /// breaks). `login` preserves the env, so setting it here reaches
    /// the shell. Harmless when libghostty falls back to
    /// `xterm-256color` (that entry lives in the system db regardless).
    private func shellEnvironmentWithTerminfo() -> [String: String] {
        var env = environment
        if let terminfo = Self.resourcesDirectory()?
            .appendingPathComponent("terminfo"),
            FileManager.default.fileExists(atPath: terminfo.path) {
            env["TERMINFO"] = terminfo.path
        }
        // A LaunchServices-launched .app inherits no LANG, leaving the
        // login shell with an unset locale. Derive a UTF-8 LANG from the
        // system region when the process carries none (terminal-launched
        // runs already have one and are left untouched).
        if let lang = ShellLocale.injectedLang(
            existing: ProcessInfo.processInfo.environment["LANG"]
        ) {
            env["LANG"] = lang
        }
        return env
    }

    /// Make the libghostty host view first responder. Called by the
    /// TabStripViewController on tab switch (the surface's NSTextInputClient
    /// view must hold focus, not this VC's plain container).
    func focus() {
        if let host = surface?.view { view.window?.makeFirstResponder(host) }
    }

    /// Ask libghostty to tear the child shell down gracefully. Called
    /// on tab close before the VC is dropped (the surface also frees
    /// in its isolated deinit, but requesting close exits the shell
    /// cleanly rather than yanking the PTY).
    func requestClose() {
        // Supersede every in-flight paced-typing task (the whole chain,
        // not just its tail) so none keeps injecting input into a
        // closing surface.
        typingGeneration &+= 1
        typingTask?.cancel()
        typingTask = nil
        // Stop the bind poll and fence any late reconnect-driven rebind so a
        // closed pane can't keep scheduling binds against a dead surface.
        terminalBindTornDown = true
        terminalBindTask?.cancel()
        terminalBindTask = nil
        surface?.requestClose()
    }

    /// Inject `text` into the surface's input pipeline. Called by
    /// the intent layer for `deviceterm tab send-input`. Forces the
    /// view to load if the VC has never been activated (background
    /// tabs that haven't been selected yet won't have run
    /// viewDidLoad, and therefore won't have called `attach`),
    /// then routes through to the surface. Throws when the surface
    /// is still unavailable after the forced load (attach failed
    /// or the surface refuses input for another reason) so the
    /// dispatcher relays the typed error rather than letting the
    /// caller believe the bytes landed.
    ///
    /// `typeDelayMillis`, when positive, animates the injection one
    /// Swift `Character` at a time with that delay between them (for
    /// screencasts, so a command reads as typed rather than pasted).
    /// The call is **non-blocking**: it validates the surface, enqueues
    /// the animation on a per-pane serial task, and returns immediately
    /// so the automation's ack (and the daemon's back-channel drain)
    /// isn't held for the typing duration. Concurrent paced calls chain
    /// in order rather than interleaving. `nil`/`0` is the synchronous
    /// instant one-shot. The delay is clamped to a sane ceiling so a
    /// fat-fingered value can't wedge the pane.
    func sendInput(_ text: String, typeDelayMillis: Int? = nil) throws {
        if surface == nil { _ = view }
        guard let surface else {
            throw TerminalSurfaceError.notAttached
        }
        guard let delay = typeDelayMillis, delay > 0 else {
            try surface.sendInput(text)
            return
        }
        // Preflight attachment before acking. The guard above only
        // proves the wrapper object exists; `attach` may still have
        // failed, leaving the engine surface nil. The paced path returns
        // before delivering any character, so a failure discovered
        // inside the task would be invisible to the caller. An empty
        // send reaches the same attach check and writes nothing.
        try surface.sendInput("")
        let clamped = min(delay, 1_000)
        let generation = typingGeneration
        let previous = typingTask
        // Add a leading delay when another paced send is still running,
        // so spacing is preserved across the command boundary instead of
        // this call's first character landing in the same instant as the
        // previous command's trailing Return. An already-finished task
        // is not a chain, hence the in-flight count rather than
        // `typingTask != nil`.
        let chained = pendingTypingTasks > 0
        pendingTypingTasks += 1
        typingTask = Task { @MainActor [weak self] in
            defer { self?.pendingTypingTasks -= 1 }
            // Serialize after any in-flight animation so two rapid
            // commands type out in order, not interleaved.
            await previous?.value
            for (index, character) in text.enumerated() {
                if index > 0 || chained {
                    try? await Task.sleep(for: .milliseconds(clamped))
                }
                // Re-check after every suspension: stop the moment the
                // pane closes (generation bumped) or this task is
                // cancelled, so a closing surface never keeps receiving
                // input. Checking `generation` (not just `isCancelled`)
                // is what stops an *earlier* queued task that
                // `requestClose` couldn't reach directly.
                guard let self,
                    !Task.isCancelled,
                    self.typingGeneration == generation
                else {
                    return
                }
                guard let surface = self.surface else { return }
                do {
                    try surface.sendInput(String(character))
                } catch {
                    // A surface refusing input mid-animation (detached
                    // pane) will refuse the rest too. Stop instead of
                    // punching a silent hole through the command.
                    return
                }
            }
        }
    }

    /// Read the surface's currently-visible viewport as plain text.
    /// Called by the intent layer for `deviceterm tab capture`. Same
    /// forced-load shape as `sendInput` so a never-activated tab
    /// still presents its scrollback rather than an empty string,
    /// but throws if the surface is still unavailable after the
    /// forced load (attach failure).
    func captureScreen() throws -> String {
        if surface == nil { _ = view }
        guard let surface else {
            throw TerminalSurfaceError.notAttached
        }
        return try surface.readScreenText()
    }

    // MARK: - TerminalSurfaceDelegate

    func terminalSurface(_ surface: any TerminalSurface, didChangeTitle title: String) {
        // OSC 0/2 title update: mirror into the chrome strip so the
        // visible label tracks the live shell prompt / running
        // command. The
        // Tab/window relabels through `onTitleChange`; the chrome no
        // longer shows the title (it's a minimal handle now), so the
        // VM doesn't need it either.
        lastOSCTitle = title.isEmpty ? nil : title
        onTitleChange?(title)
    }

    func terminalSurface(
        _ surface: any TerminalSurface,
        didChangeWorkingDirectory path: String
    ) {
        lastWorkingDirectory = path.isEmpty ? nil : path
        onWorkingDirectoryChange?(path)
    }

    func terminalSurface(_ surface: any TerminalSurface, didExitWithCode code: Int32?) {
        onExit?(code)
    }

    func terminalSurfaceWantsBell(_ surface: any TerminalSurface) {
        NSSound.beep()
    }

    func terminalSurface(
        _ surface: any TerminalSurface,
        didUpdateScrollbar state: ScrollbarState
    ) {
        latestScrollbarState = state
        scrollWrapper?.updateScrollbar(state)
        onScrollbarUpdate?(state)
    }

    func terminalSurface(
        _ surface: any TerminalSurface,
        didChangeBackgroundColor color: TerminalBackgroundColor
    ) {
        scrollWrapper?.updateBackgroundColor(color)
    }

    // MARK: - Menu selectors

    // These three carry AppKit's *standard* editing selectors (`copy:`,
    // `paste:`, and `selectAll:`) rather than terminal-specific names.
    // One Edit menu then serves
    // both kinds of responder: a focused terminal resolves them here,
    // while a focused text field (the rename sheet, the custom-coordinates
    // sheet) resolves them on its `NSText` field editor. Terminal-specific
    // names would leave those fields with a dead Edit menu.
    //
    // There is deliberately no `cut:`. A terminal has no editable region,
    // so the Cut item correctly reads disabled here and stays live for
    // text fields.

    /// Edit ▸ Copy (⌘C) and the right-click "Copy": triggers
    /// libghostty's `copy_to_clipboard` binding action via the surface.
    /// Selection state and the macOS pasteboard write are handled by the
    /// engine; no-op when nothing is selected.
    @objc
    func copy(_ sender: Any?) {
        surface?.copyToClipboard()
    }

    /// Edit ▸ Paste (⌘V) and the right-click "Paste": triggers
    /// libghostty's `paste_from_clipboard` binding action. Multi-line
    /// paste may surface the engine's unsafe-paste confirm sheet.
    @objc
    func paste(_ sender: Any?) {
        surface?.pasteFromClipboard()
    }

    /// Edit ▸ Select All (⌘A): triggers libghostty's `select_all`
    /// binding action, selecting the scrollback and viewport together so
    /// a following Copy takes the whole buffer.
    ///
    /// `override` because `NSResponder` already declares `selectAll(_:)`;
    /// `copy(_:)` and `paste(_:)` above are not declared there, so they
    /// don't need it.
    @objc
    override func selectAll(_ sender: Any?) {
        surface?.selectAll()
    }

    /// Edit ▸ Clear Buffer (⌘K) and the right-click "Clear": triggers
    /// libghostty's `clear_screen` binding action. Wipes the visible
    /// viewport AND the scrollback history (matches the macOS
    /// Terminal.app ⌘K convention users expect from a Clear menu item).
    /// Shell-side history (`$HISTFILE`) is untouched; no-op on the
    /// alternate screen.
    @objc
    func clearTerminalScreen(_ sender: Any?) {
        surface?.clearScreen()
    }

    /// Right-click "Close Pane": drops just this terminal on a
    /// multi-terminal tab; on the tab's last terminal it requests a
    /// tab close, which applies the tab-close prompt policy (a shell
    /// exit closes silently). Routing decision lives in the container
    /// so this VC stays unaware of tab arithmetic.
    @objc
    func closeTerminalPaneViaMenu(_ sender: Any?) {
        onClosePaneRequested?()
    }

    /// Right-click "Open in New Tab": opens a fresh tab in the same
    /// window, seeded with the source tab's latest cwd. The container
    /// owns the dispatch (it has the router); this VC just signals
    /// the intent.
    @objc
    func openCurrentInNewTab(_ sender: Any?) {
        onOpenInNewTabRequested?()
    }

    /// Right-click "Split Right": splits just this pane, adding a
    /// terminal sibling along a vertical divider (panes side-by-side).
    /// When the pane's parent split is stacked, this wraps the pane in
    /// a fresh nested sub-split rather than re-orienting the tab.
    @objc
    func splitTerminalRight(_ sender: Any?) {
        onSplitRequested?(true)
    }

    /// Right-click "Split Down": symmetric to `splitTerminalRight`,
    /// horizontal divider (panes stacked).
    @objc
    func splitTerminalDown(_ sender: Any?) {
        onSplitRequested?(false)
    }

    /// View > Zoom In (⌘=): increase font size by one step.
    /// Targets the focused terminal pane via the responder chain.
    @objc
    func zoomTerminalIn(_ sender: Any?) {
        surface?.zoomIn()
    }

    /// View > Zoom Out (⌘-): decrease font size by one step.
    @objc
    func zoomTerminalOut(_ sender: Any?) {
        surface?.zoomOut()
    }

    /// View > Reset Zoom (⌘0): restore the config-defined size.
    @objc
    func resetTerminalZoom(_ sender: Any?) {
        surface?.resetZoom()
    }
}

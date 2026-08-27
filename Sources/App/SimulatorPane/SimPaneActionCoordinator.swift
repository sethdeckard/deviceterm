// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import Foundation

/// The sim pane's menu/chrome action wiring,
/// lifted out of `TabContentViewController`. One instance per tab. It owns
/// the recording-destination map (written on record-start, consumed on
/// record-stop and on cleanup teardown) and the shutdown→boot resequencing,
/// screenshot/record shell-outs, Finder reveals, Simulator.app launch,
/// install, and the resurrect-watch dispatch: everything the sim pane's VC
/// callbacks fire. Device and pending panes wire far less, so they stay on
/// the VC.
///
/// Live tab credentials (the primary terminal's session + cap) are read from
/// the tab view model at action time, because terminals can change between
/// wiring and invocation, so nothing is snapshotted at construction.
@MainActor
final class SimPaneActionCoordinator {
    /// The close-prompt seam: context, device name, force-ask, the window
    /// to anchor the sheet to, and whether the pane being asked about is
    /// still there. Injected so tests can answer it without a UI.
    typealias PaneClosePrompt = @MainActor (
        CloseContext,
        String,
        Bool,
        NSWindow?,
        @escaping CloseTargetLiveness
    ) async -> TabCloseDecision

    private let tabID: TabID
    private let router: Router
    private let daemonClient: any DeviceControlling
    private let simResurrect: SimResurrect
    /// The window's tab-list nav state. A `var` (not `let`) because a
    /// cross-window tab move relocates the tab's `TabState` into a
    /// different window's `TabListViewModel` instance; the owning
    /// `TabContentViewController` calls `rebind` so credential + pane
    /// lookups keep resolving against the tab's new home. Every closure
    /// here reads it live through `self`, so repointing is enough.
    private var tabListVM: TabListViewModel
    /// The window the tab currently lives in, for scoping the close
    /// prompt's "For this window" suppression. A `var` and repointed by
    /// `rebind` for the same reason `tabListVM` is: a cross-window move
    /// puts the tab under a different window id.
    private var windowID: WindowID
    /// Pane admissions with a close in flight. The roster lookup suspends,
    /// so a second ⌘W (or a double-click on Close Pane) arrives before the
    /// first request reaches its prompt and would ask again.
    ///
    /// A marker outlives the dispatch that ends the request. `dispatch`
    /// only enqueues, so clearing it on the way out would reopen the window
    /// it exists to close while the route waits behind the drain. Markers
    /// are instead pruned against current admissions at the start of the
    /// next close request, which suppresses the duplicate without blocking
    /// a pane that has since been replaced or re-admitted.
    private var closingPanes: Set<PaneAdmission> = []
    /// Raises the pane-close prompt. Injected so a test can drive the
    /// decision without a modal, the same seam the Router uses for
    /// `detectWorktreeName`. Production reads the config fresh on each ask
    /// so an edit made while the app runs takes effect.
    private let askPaneClose: PaneClosePrompt

    /// View the close prompt anchors its sheet to, set by the owning
    /// `TabContentViewController` once its view exists. Read at prompt
    /// time rather than captured, so it follows the pane across a
    /// cross-window move; `nil` falls back to an app-modal alert.
    weak var hostView: NSView?
    /// Active simctl recordVideo destinations, keyed by sim UDID. Populated
    /// by `onRecordStart`; consumed (and removed) by `onRecordStop` so the
    /// stop closure can reveal the finalized file in Finder, and by
    /// `stopRecordingForCleanup` on teardown. Only the recording `Process`
    /// itself lives on the VC (menu validation reads it).
    private var recordingDestinations: [String: String] = [:]

    /// The tab's primary-terminal session + cap, the ownership binding a
    /// reboot / erase re-asserts. Read live; empty strings if the tab is
    /// already gone (the action is then a harmless no-op).
    private var credentials: (sessionId: String, capability: String) {
        let primary = tabListVM.tab(id: tabID)?.primaryTerminal
        return (primary?.sessionId ?? "", primary?.capability ?? "")
    }

    init(
        tabID: TabID,
        router: Router,
        daemonClient: any DeviceControlling,
        simResurrect: SimResurrect,
        tabListVM: TabListViewModel,
        windowID: WindowID,
        askPaneClose: @escaping PaneClosePrompt = {
            await CloseDecisions.paneClose(
                config: ConfigFile(),
                state: .shared,
                context: $0,
                deviceName: $1,
                window: $3,
                whileTargetLives: $4,
                alwaysAsk: $2
            )
        }
    ) {
        self.tabID = tabID
        self.router = router
        self.daemonClient = daemonClient
        self.simResurrect = simResurrect
        self.tabListVM = tabListVM
        self.windowID = windowID
        self.askPaneClose = askPaneClose
    }

    /// Repoint at the tab's new-home nav state after a cross-window move.
    func rebind(tabListVM: TabListViewModel, windowID: WindowID) {
        self.tabListVM = tabListVM
        self.windowID = windowID
    }

    /// Shut down, and on success drop the owned-sim mirror's claim.
    ///
    /// The daemon disowns the sim as part of the shutdown, so a claim left
    /// standing until the next poll is one recovery would re-assert. Whether
    /// the sim is Booted is the daemon's only gate, so if something else boots
    /// that udid in between, deviceterm would claim a device it no longer owns.
    ///
    /// The reboot legs shut down before booting, so they pass through here on
    /// the way and record the sim again on the boot.
    private func shutdownAndForget(udid: String) async {
        do {
            try await daemonClient.shutdownDevice(udid: udid)
        } catch {
            return
        }
        router.noteSimShutdown(udid: udid)
    }

    /// Retain a GUI boot claim before sending the boot request, then reconcile
    /// it whether the response succeeds or becomes uncertain.
    ///
    /// All three boot legs here (Reboot, live reboot, post-erase) use the same
    /// path. The claim outlives an unanswered RPC and is promoted only after
    /// the daemon observes Booted.
    ///
    /// Module-internal rather than private so a test can drive it without a
    /// live pane view controller, which is what the boot legs above wire it to.
    func bootAndReconcileOwnership(
        udid: String,
        sessionId: String,
        capability: String
    ) async {
        let claim = router.beginGUIBootClaim(udid: udid, sessionId: sessionId)
        do {
            _ = try await daemonClient.bootDeviceWithGeneration(
                udid: udid,
                sessionId: sessionId,
                capability: capability,
                claim: claim
            )
            router.finishGUIBootRequest(attemptId: claim.attemptId, outcome: .accepted)
        } catch {
            router.finishGUIBootRequest(
                attemptId: claim.attemptId,
                outcome: bootClaimOutcome(for: error)
            )
        }
    }

    private func bootClaimOutcome(for error: Error) -> BootClaimRequestOutcome {
        guard let clientError = error as? DaemonClientError else { return .rejected }
        switch clientError {
        case .daemon:
            return .rejected

        case .transport, .timedOut, .versionMismatch, .decode,
            .shutdownNotAcknowledged, .shutdownTimedOut:
            return .uncertain
        }
    }

    /// Close a sim pane, prompting when its sim is one deviceterm owns, is
    /// still Booted, and is claimed by no live session in another tab. An
    /// owner that is a dead session, or no owner at all, still prompts.
    ///
    /// Detaching is the pane-only close: the surface goes and the sim keeps
    /// running, owned and counted by the status item, which is easy to do by
    /// accident and hard to notice afterwards. Pane, tab, and window close
    /// therefore ask the same question against the same suppression state.
    /// Quit asks its own and stores it separately.
    ///
    /// A sim that is stopped, borrowed, or another tab's raises nothing and
    /// closes straight through. One the daemon could not be asked about
    /// raises the prompt with the stored answer ignored, because a stored
    /// `shutdown` would otherwise stop a simulator nothing verified.
    ///
    /// Not reached by the resurrect re-mount, which dispatches the route
    /// itself: that detach is an internal step of a re-attach, and the sim
    /// it names is deliberately left running.
    ///
    /// Module-internal rather than private, like `bootAndReconcileOwnership`
    /// above, so a test can drive it without a live pane view controller.
    func requestClosePane(udid: String, displayName: String) async {
        // Neither the paneId nor the udid identifies what the user is
        // closing. A resurrect replaces the pane under the same udid, and a
        // re-attach re-admits the same paneId under a new attachment, so the
        // admission is the thing to hold and to fence on.
        guard let admission = simPane(udid: udid)?.admission else { return }
        closingPanes.formIntersection(liveAdmissions())
        guard closingPanes.insert(admission).inserted else { return }
        var dispatched = false
        defer { if !dispatched { closingPanes.remove(admission) } }

        let lookup = await daemonClient.lookUpOwnedSim(udid: udid)
        // The tab can close, the pane can be dropped, or it can be
        // re-admitted while the read is outstanding. Re-check before either
        // acting or asking: prompting about a pane that is already gone is
        // as wrong as closing whatever took its place. The second check
        // after the prompt covers the time the user spent in it.
        guard simPane(udid: udid)?.admission == admission else { return }

        let shouldAsk: Bool
        switch lookup {
        case .notRunning:
            shouldAsk = false

        case .unknown:
            shouldAsk = true

        case let .running(owner):
            // Sampled here, not before the read: a tab opened while the
            // read was in flight still counts, and its simulator is not
            // this pane's to stop.
            shouldAsk = OwnedSimDecision.isOursToStop(
                ownedBySession: owner,
                claimedElsewhere: sessionsLiveInOtherTabs()
            )
        }

        var mode = PaneCloseMode.detach
        if shouldAsk {
            // The tab outlives a pane close, so "For this window" is always
            // an available scope here.
            let context = CloseContext(windowID: windowID, hasOtherTabsInWindow: true)
            // The same admission fence the checks either side of this
            // suspension use, handed to the prompt so a sheet asking
            // about a pane that automation drops comes down instead of
            // waiting for an answer nothing would act on.
            switch await askPaneClose(
                context,
                displayName,
                lookup == .unknown,
                hostView?.window,
                { [weak self] in self?.simPane(udid: udid)?.admission == admission }
            ) {
            case .detach:
                break

            case .shutdown:
                mode = .shutdown

            case .cancel:
                return
            }
            guard simPane(udid: udid)?.admission == admission else { return }
        }
        dispatched = true
        router.dispatch(
            .detachSimPane(tab: tabID, udid: udid, mode: mode, expecting: admission)
        )
    }

    /// Current admissions, for pruning stale close markers before another
    /// request is accepted.
    private func liveAdmissions() -> Set<PaneAdmission> {
        Set((tabListVM.tab(id: tabID)?.simPanes ?? []).map(\.admission))
    }

    /// Resolves current pane state for the admission checks either side of
    /// a suspension.
    private func simPane(udid: String) -> SimPaneState? {
        tabListVM.tab(id: tabID)?.simPanes.first { $0.udid == udid }
    }

    /// Session ids belonging to tabs other than this one, anywhere in the
    /// workspace. A sim attributed to one of these is that tab's to stop,
    /// not this pane's, even though both name the same udid.
    ///
    /// Spans windows rather than just this one: booting the same udid from
    /// a tab in another window leaves the same stale pane behind here.
    private func sessionsLiveInOtherTabs() -> Set<String> {
        var sessions: Set<String> = []
        for window in router.workspace.windows {
            for tab in window.tabs.tabs where tab.id != tabID {
                sessions.formUnion(tab.terminals.map(\.sessionId))
            }
        }
        return sessions
    }

    func wire(paneVC: SimulatorPaneViewController, simPane: SimPaneState) {
        let tabID = self.tabID
        let udid = simPane.udid
        let displayName = simPane.displayName
        // Stamp tabID before viewDidLoad runs so the chrome's drag
        // host has it when constructed; the chrome strip drag-source
        // ships `(tabID, slot)` in the pasteboard payload and the
        // destination decoder rejects cross-tab drags. Without this
        // the drag would be silently dropped.
        paneVC.tabID = tabID
        paneVC.onClose = { [weak self] in
            Task { @MainActor in
                await self?.requestClosePane(udid: udid, displayName: displayName)
            }
        }
        paneVC.onReboot = { [weak self] in
            guard let self else { return }
            let (sessionId, capability) = self.credentials
            Task { @MainActor in
                await self.bootAndReconcileOwnership(
                    udid: udid,
                    sessionId: sessionId,
                    capability: capability
                )
            }
        }
        paneVC.onLiveReboot = { [weak self, weak paneVC] in
            guard let self, let paneVC else { return }
            let (sessionId, capability) = self.credentials
            Task { @MainActor in
                // Sequence the shutdown→boot half through the pane's
                // locally-observed `.shutdown` state, which the
                // daemon's pane subscription drives once
                // CoreSimulator has fully left ShuttingDown. The
                // boot only fires once that signal arrives. A
                // fixed sleep would either hurt the fast case or
                // race the slow one (CoreSimulator's
                // ShuttingDown→Shutdown timing varies from sub-100ms
                // on fresh phones to multiple seconds on slow
                // machines or watchOS sims), and an unconditional
                // boot-after-timeout would silently fail the same
                // way the fixed-delay shape did.
                //
                // The poll is capped at ~5s of 25ms ticks. On a sim
                // that's still shutting down past the cap we
                // bail without booting; the shutdown overlay's
                // existing Reboot button is the recovery path once
                // the transition finally completes. Ownership is
                // re-asserted on the boot leg.
                await self.shutdownAndForget(udid: udid)
                var attempts = 0
                while paneVC.currentState != .shutdown, attempts < 200 {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    attempts += 1
                }
                guard paneVC.currentState == .shutdown else { return }
                await self.bootAndReconcileOwnership(
                    udid: udid,
                    sessionId: sessionId,
                    capability: capability
                )
            }
        }
        paneVC.onEraseContent = { [weak self, weak paneVC] in
            guard let self, let paneVC else { return }
            let (sessionId, capability) = self.credentials
            Task { @MainActor in
                // Erase requires the sim to be shut down. Reuses the
                // live-reboot shape: shutdown → wait for `.shutdown`
                // (capped at ~5s of 25ms ticks) → erase → boot.
                // Same recovery-by-fall-through-bail discipline: if
                // the transition never lands the action stops short
                // of the shell-out and the user can retry via the
                // shutdown overlay's Reboot button once the
                // transition completes. Ownership is re-asserted
                // on the post-erase boot leg so the wiped sim
                // re-mounts under this session.
                await self.shutdownAndForget(udid: udid)
                var attempts = 0
                while paneVC.currentState != .shutdown, attempts < 200 {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    attempts += 1
                }
                guard paneVC.currentState == .shutdown else { return }
                do {
                    try await SimulatorShellOut.eraseContent(udid: udid)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Erase failed"
                    alert.informativeText = "\(error)"
                    alert.alertStyle = .critical
                    alert.runModal()
                    return
                }
                await self.bootAndReconcileOwnership(
                    udid: udid,
                    sessionId: sessionId,
                    capability: capability
                )
            }
        }
        paneVC.onScreenshot = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let path = self.screenshotDestination(for: displayName)
                do {
                    try await SimulatorShellOut.captureScreenshot(
                        udid: udid,
                        to: path
                    )
                    // Reveal the new file in Finder. The user picked
                    // the menu item, so a side effect that surfaces
                    // the output is the natural follow-through,
                    // matching Apple's Simulator.app's
                    // "screenshot-in-Finder" behavior.
                    NSWorkspace.shared.selectFile(
                        path,
                        inFileViewerRootedAtPath: ""
                    )
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Screenshot failed"
                    alert.informativeText = "\(error)"
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
        paneVC.onRecordStart = { [weak self, weak paneVC] in
            guard let self, let paneVC else { return }
            let path = self.recordingDestination(for: displayName)
            do {
                let process = try SimulatorShellOut.startRecording(
                    udid: udid,
                    to: path
                )
                paneVC.recordingProcess = process
                // Remember where we put the file so the stop closure
                // (which doesn't take parameters) can reveal it.
                self.recordingDestinations[udid] = path
            } catch {
                let alert = NSAlert()
                alert.messageText = "Recording failed to start"
                alert.informativeText = "\(error)"
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
        paneVC.onRecordStop = { [weak self, weak paneVC] in
            guard let self, let paneVC,
                let process = paneVC.recordingProcess else { return }
            paneVC.recordingProcess = nil
            let path = self.recordingDestinations.removeValue(forKey: udid)
            Task { @MainActor in
                await SimulatorShellOut.stopRecording(process)
                // Reveal the finalized mp4 in Finder when the user
                // ended the recording deliberately, matching the
                // Screenshot flow's follow-through.
                if let path {
                    NSWorkspace.shared.selectFile(
                        path,
                        inFileViewerRootedAtPath: ""
                    )
                }
            }
        }
        paneVC.onOpenInSimulatorApp = {
            // Resolve Simulator.app through Launch Services so the
            // selected Xcode (DEVELOPER_DIR, Xcode-beta, a
            // non-default install path) wins. Hardcoding
            // `/Applications/Xcode.app/...` breaks for those setups
            // even when the daemon's CoreSimulator bridge happily
            // uses the same alternative Xcode. Foregrounds the sim
            // with `-CurrentDeviceUDID <udid>`. No daemon side
            // effects.
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.iphonesimulator"
            )
            guard let url else {
                let alert = NSAlert()
                alert.messageText = "Couldn't find Simulator.app"
                alert.informativeText = "Launch Services has no "
                    + "registration for com.apple.iphonesimulator. "
                    + "Open Xcode once to register it, then retry."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["-CurrentDeviceUDID", udid]
            Task { @MainActor in
                do {
                    _ = try await NSWorkspace.shared
                        .openApplication(at: url, configuration: config)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't open Simulator.app"
                    alert.informativeText = "\(error)"
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
        paneVC.onInstallApp = { url in
            Task { @MainActor in
                do {
                    try await SimulatorShellOut.installApp(
                        udid: udid,
                        path: url.path
                    )
                    let alert = NSAlert()
                    alert.messageText = "Installed \(url.lastPathComponent)"
                    alert.informativeText = "on \(displayName)."
                    alert.alertStyle = .informational
                    alert.runModal()
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Install failed"
                    alert.informativeText = "\(error)"
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
        paneVC.onShutDownSim = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.shutdownAndForget(udid: udid)
            }
        }
        paneVC.onRevealInFinder = {
            // The sim's CoreSimulator device folder is the natural
            // root for poking at app data / logs / preferences. We
            // reveal it at the FOLDER level (Finder opens the
            // parent, with this folder highlighted) so the user
            // can navigate down into the `data/` subtree from a
            // familiar starting point.
            //
            // CoreSimulator names each device directory with the uppercase
            // UUID, while a mounted pane carries the daemon's canonical
            // lowercase. A case-insensitive volume forgives the difference
            // and a case-sensitive one does not, so ask for the spelling
            // that is actually on disk.
            let path = NSHomeDirectory()
                + "/Library/Developer/CoreSimulator/Devices/\(udid.uppercased())"
            NSWorkspace.shared.selectFile(
                path,
                inFileViewerRootedAtPath: ""
            )
        }
        paneVC.onStateChange = { [weak self, weak paneVC] state in
            guard let self else { return }
            switch state {
            case .shutdown:
                self.simResurrect.watch(
                    udid: udid,
                    displayName: displayName
                ) { [weak self] in
                    self?.dispatchResurrect(udid: udid)
                }

            case .rendering:
                self.simResurrect.unwatch(udid: udid)

            default:
                break
            }
            _ = paneVC  // keep the closure capturing the pane lifetime
        }
    }

    /// Stop an in-flight recording on a pane being removed (close
    /// pane / tab close / window close / quit). Detaches the SIGINT
    /// + flush so the cleanup path stays synchronous. The simctl
    /// child writes its mp4 trailer and exits on its own; the file
    /// stays on Desktop where the user can find it later. Skips
    /// the Finder reveal that the deliberate Stop button does;
    /// surfacing N Finder windows from a tab-close with multiple
    /// recordings would be obnoxious. No-op if no recording is in
    /// flight.
    func stopRecordingForCleanup(_ paneVC: SimulatorPaneViewController) {
        guard let process = paneVC.recordingProcess else { return }
        paneVC.recordingProcess = nil
        recordingDestinations.removeValue(forKey: paneVC.udid)
        Task.detached {
            await SimulatorShellOut.stopRecording(process)
        }
    }

    /// Re-attach a sim that shut down out from under its pane. Fired by the
    /// SimResurrect watch set in `onStateChange`.
    ///
    /// Dispatch one `.resurrectSimPane` route so the handler can replace the
    /// pane's existing leaf with a placeholder, preserving its split. It
    /// bypasses `requestClosePane` because this is an automatic pane-record
    /// replacement, not a user-initiated close.
    private func dispatchResurrect(udid: String) {
        router.dispatch(.resurrectSimPane(tab: tabID, udid: udid))
    }

    private func screenshotDestination(for displayName: String) -> String {
        desktopPath(name: "Simulator Screen Shot - \(displayName)", ext: "png")
    }

    /// Sibling to `screenshotDestination` for `simctl io recordVideo`.
    /// Same format, different prefix + extension. Apple's Simulator.app
    /// uses "Simulator Screen Recording" for the video file.
    private func recordingDestination(for displayName: String) -> String {
        desktopPath(name: "Simulator Screen Recording - \(displayName)", ext: "mp4")
    }

    private func desktopPath(name: String, ext: String) -> String {
        let desktop = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Desktop")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        return desktop
            .appendingPathComponent("\(name) - \(stamp).\(ext)")
            .path
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import Metal
import os
import ServiceManagement

/// Logs launch-time helper-registration repair offers and outcomes for later
/// diagnosis.
private let registrationLog = Logger(subsystem: "com.deviceterm", category: "registration")

/// How long a launch waits for another copy of DeviceTerm to release the repair
/// lock before giving up. An allowance rather than an expected duration; the
/// common holder is a launch that is merely connecting.
private let startupRepairLockWaitSeconds: TimeInterval = 10

/// Map the mid-session mismatch outcome onto the shared situation vocabulary.
///
/// `.confirmed` becomes "accepted", not "stopped": the daemon acknowledges the
/// request a grace period before it exits, so acceptance is all it ever
/// promised.
private func versionMismatchSituation(
    from outcome: VersionMismatchOutcome
) -> UpdateRestartSituation {
    switch outcome.shutdown {
    case .confirmed:
        return UpdateRestartSituation(
            cause: .shutdownAcceptedWhileRunning,
            detail: "\(outcome.mismatch)"
        )

    case let .indeterminate(reason):
        return UpdateRestartSituation(
            cause: .replacedWhileRunningUnconfirmed(reason),
            detail: "\(outcome.mismatch)\n\(reason)"
        )
    }
}

/// What the alert says for each cause.
///
/// No mention of logging out anywhere: it names neither what it fixes nor how to
/// do it. Restarting the Mac appears only where DeviceTerm has run out of
/// remedies of its own.
private func restartPlainText(for situation: UpdateRestartSituation) -> String {
    let body: String
    switch situation.cause {
    case .shutdownAcceptedWhileRunning:
        body = "DeviceTerm's background helper was updated. The old one accepted "
            + "the request to close. Quit and reopen DeviceTerm to finish."

    case .replacedWhileRunningUnconfirmed:
        body = "DeviceTerm's background helper was updated, and DeviceTerm "
            + "couldn't confirm the old one is closing. Quit and reopen "
            + "DeviceTerm; if this comes back, restart your Mac."

    case .helperCouldNotBeStopped:
        body = "DeviceTerm couldn't get a matching background helper running "
            + "after trying to replace the old one. Restart your Mac; if the "
            + "problem comes back, check whether another copy of DeviceTerm is "
            + "installed, and that DeviceTerm is allowed to run in the background "
            + "under System Settings ▸ General ▸ Login Items & Extensions."

    case let .replacementStillIncompatible(daemonVersion):
        body = "The background helper is a different version of DeviceTerm "
            + "(\(daemonVersion)). If another copy of DeviceTerm is installed or "
            + "running, that one may own the helper."

    case .replacementDidNotStart:
        body = "DeviceTerm couldn't reach the replacement background helper. Open "
            + "System Settings ▸ General ▸ Login Items & Extensions and check "
            + "DeviceTerm is allowed to run in the background."

    case .registrationNotRestored:
        body = "The old background helper stopped, but DeviceTerm couldn't "
            + "register the new one. Open System Settings ▸ General ▸ Login Items "
            + "& Extensions and check DeviceTerm is allowed to run in the "
            + "background."

    case .registrationStateUnknown:
        body = "DeviceTerm couldn't determine or complete its background helper's "
            + "registration with macOS. Open "
            + "System Settings ▸ General ▸ Login Items & Extensions and check "
            + "DeviceTerm is allowed to run in the background; if this comes back, "
            + "restart your Mac."

    case .registrationRepairAbandoned:
        body = "DeviceTerm is still rebuilding its background helper's "
            + "registration with macOS. Reopening may take a moment longer than "
            + "usual."

    case .registrationRepairStalled:
        body = "Another DeviceTerm launch may still be starting up or rebuilding "
            + "the background helper's registration. Reopening won't speed it up. "
            + "Check DeviceTerm is "
            + "allowed to run in the background under System Settings ▸ General ▸ "
            + "Login Items & Extensions; if it stays stuck, restart your Mac."
    }
    // The re-registration is a visible thing DeviceTerm did to the system, so
    // the user gets told rather than being left to wonder what triggered the
    // notification macOS is about to show them.
    let aside = situation.reregistered
        ? "\n\nDeviceTerm rebuilt the helper's registration, so macOS may show a "
            + "Background Activity notification about it."
        : ""
    return "\(body)\(aside)\n\n\(situation.detail)"
}

/// The composition root and AppKit-side reconcile
/// layer. Constructs the WorkspaceViewModel + Router (and the shared
/// PaneResurrect), then `observe()`s the workspace and reconciles its
/// WindowControllers to match. Every nav intent (menu actions, the
/// cold-start orphan flow, the close-window path, ⌘Q quit) dispatches a
/// Route through the Router. The router does the daemon record work
/// (session.create, device.attach, pane.closeById, session.close, shutdown
/// fan-out); the glue here renders state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    /// Whether the startup repair lock was taken, and what to show if not.
    private enum StartupLockAcquisition {
        case acquired(RegistrationRepairLock.Handle)
        case surrender(UpdateRestartSituation)
    }

    /// Composition root holds the *concrete* `DaemonClient`: it owns
    /// the connection lifecycle (`connect()` + version handshake), which
    /// is deliberately not a role protocol. Children get injected role
    /// types; the router gets Session/Device/Pane.
    private let daemonClient: DaemonClient
    private let workspace = WorkspaceViewModel()
    private lazy var router = Router(
        workspace: workspace,
        daemon: daemonClient,
        rpcPerformance: daemonClient.rpcPerformance
    )
    private lazy var paneResurrect = PaneResurrect(daemonClient: daemonClient)
    /// The single consumer of `RouteIntent` from every external
    /// source. Wired with `self` as the `IntentActionDelegate` so
    /// intents that don't fit a Route shape (tab rename) reach
    /// the right TabStripVC via the window/tab maps below.
    private lazy var intentDispatcher = IntentDispatcher(
        workspace: workspace,
        router: router,
        actionDelegate: self
    )
    /// Drains the daemon's `app.commands` back-channel and dispatches
    /// each received intent. Started after the daemon connection is
    /// up; stopped during quit.
    private lazy var appCommandSubscriber = AppCommandSubscriber(
        dispatcher: intentDispatcher,
        daemon: daemonClient
    )
    /// The single caller of `session.restoreBatch`: restart restoration and
    /// ongoing authoritative inventory reconciliation, serialized behind a
    /// dirty flag with bounded coalescing. Fed the live workspace inventory.
    private lazy var inventorySync = InventorySyncCoordinator(
        InventorySyncCoordinator.Dependencies(
            buildInventory: { [weak self] in
                guard let self else { return [] }
                return SessionRestoreInventory.build(
                    from: self.workspace.windows.flatMap(\.tabs.tabs)
                )
            },
            sendBatch: { [weak self] inventory in
                guard let self else { return nil }
                return (try? await self.daemonClient.restoreBatch(sessions: inventory))?
                    .sessionIds
            },
            generation: { [weak self] in self?.daemonClient.reconnectGeneration ?? 0 },
            onReconnectSynced: { [weak self] inventory in
                guard let self else { return }
                // Reconnect only: close any restored-but-no-longer-live session,
                // then fire the terminal-rebind observers.
                await self.closeGhostSessions(restored: inventory)
                self.router.resumeBootClaimsAfterSessionRestore()
                // Cohorts live only in the helper's memory too. Attempt each
                // reinstall before firing the rebind observers; retryable
                // failures continue in the background, and each recovered
                // pane mount schedules another reconcile with its binding.
                await self.router.reconcileAllCohorts()
                self.daemonClient.notifyReconnect()
                // Pane records live only in the helper's memory. This
                // connection may have reached a replacement holding none of
                // the ones the workspace is showing, or the same helper with
                // them intact; re-attaching is right either way, because a
                // surviving record comes back to its owning session rather
                // than being duplicated, and neither attach verb fails a
                // re-attach over machinery only a fresh create needs. Sessions
                // are restored by now, which is what lets the attaches
                // authenticate; the terminal rebinds have been scheduled
                // alongside them.
                self.router.dispatch(.recoverPanes)
            },
            reportContractViolation: { [weak self] in self?.reportRestoreContractViolation() },
            sleep: { nanos in
                do { try await Task.sleep(nanoseconds: nanos); return true } catch { return false }
            }
        )
    )

    /// Decides when to propose restarting the helper, and runs the restart.
    /// Both the automatic prompt (an unanswered call whose follow-up ping went
    /// unanswered too) and the menu item land here, so the two paths can't
    /// drift.
    private lazy var helperRecovery = HelperRecoveryCoordinator(
        HelperRecoveryCoordinator.Dependencies(
            prompt: { [weak self] reason in
                self?.promptForHelperRestart(reason) ?? .cancel
            },
            terminate: { [weak self] generation in
                await self?.daemonClient.terminateHelper(expectedGeneration: generation)
                    ?? .alreadyGone
            },
            reconnect: { [weak self] in await self?.daemonClient.reconnect() },
            report: { [weak self] outcome in self?.reportHelperRestartFailure(outcome) },
            rearmDetection: { [weak self] in self?.daemonClient.rearmUnresponsiveDetection() }
        )
    )

    /// AppKit windows currently visible, keyed by the WindowState id.
    /// Reconciled from `workspace.windows`; dropped synchronously in
    /// `windowWillClose` so a Dock-icon reopen during a slow teardown
    /// sees the app as windowless and gets a fresh window.
    private var windowControllerByID: [WindowID: WindowController] = [:]
    /// Windows the user has closed but whose Router teardown is still in
    /// flight. Reconcile skips them so a still-present WindowState
    /// doesn't get a recreated WC before the Router removes it.
    private var closingWindowIDs: Set<WindowID> = []
    /// The close mode `windowShouldClose` resolved for an in-flight
    /// user-initiated close (prompted or not). `windowWillClose`
    /// reads (and consumes) it on the matching window; absent means
    /// the close never went through `windowShouldClose`'s async path
    /// (a Router-driven close, ⌘Q quit), so `.detach` is the safe
    /// default.
    private var pendingCloseModeByID: [WindowID: PaneCloseMode] = [:]
    private var observation: ObservationToken?
    /// Observation that re-supplies the daemon's inventory when the live session
    /// set changes (see `markInventoryDirtyIfChanged`). Non-smoke only.
    private var inventoryObservation: ObservationToken?
    /// The live session-id set last handed to the inventory coordinator, so the
    /// observation marks dirty only on an actual session-set change.
    private var lastInventorySessionIDs: Set<String> = []
    private var connected = false
    /// Set once the should-never-happen restore-contract violation (a live
    /// terminal missing its immutable short id) has been surfaced, so the
    /// non-fatal notice isn't shown repeatedly across reconnects.
    private var restoreContractViolationReported = false
    /// Set when launched with `--smoke` (`scripts/gui-smoke.sh`).
    private let smokeMode = CommandLine.arguments.contains("--smoke")
    /// Singleton Help > Third-Party Notices window; re-fronted rather
    /// than re-created so repeat invocations don't stack windows.
    private var thirdPartyNoticesWC: ThirdPartyNoticesWindowController?
    /// Singleton About window (app-menu "About DeviceTerm"); re-fronted
    /// like the notices window.
    private var aboutWC: AboutWindowController?
    /// Sparkle auto-update controller (nil under `--smoke`). Owns the
    /// updater + the unobtrusive pill; backs "Check for Updates…".
    private var updateController: UpdateController?
    /// Live only while the Settings… create-confirmation is on screen.
    private var settingsPromptWC: SettingsPromptWindowController?
    /// Live only while the Mirror Physical Device… picker is on screen.
    private var devicePickerWC: DevicePickerWindowController?

    init(daemonClient: DaemonClient) {
        self.daemonClient = daemonClient
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Probe Metal up front; every sim pane mounts an MTKView, so a
        // host without Metal (vanishingly rare on real hardware; every
        // Mac that runs macOS 14+ has it, but VMs without GPU
        // passthrough don't) would crash the first time the user
        // opened a sim pane. Surface a clear NSAlert at launch instead
        // of crashing later from inside `SimulatorContentView.init`.
        guard MTLCreateSystemDefaultDevice() != nil else {
            if smokeMode { smokeFail("Metal not available on this host") }
            fail(
                "DeviceTerm requires Metal to render simulator panes. "
                + "This host doesn't expose a Metal device, so sim panes "
                + "cannot be mounted. (Common cause: running in a VM "
                + "without GPU passthrough.)"
            )
            return
        }
        // Start Sparkle auto-update, driven by the `auto-update` config.
        // Skipped under `--smoke` so the hermetic gate never reaches the
        // network or Sparkle's scheduler.
        if !smokeMode {
            updateController = UpdateController(policyProvider: {
                AutoUpdatePolicy.resolve(ConfigFile().value(forKey: AutoUpdatePolicy.configKey))
            })
        }
        Task { @MainActor [self] in
            // Held from the reconciliation through the version handshake; see
            // the acquisition below. Released once a compatible helper is
            // answering, after which any further disruption is mid-session and
            // follows the reconnect path's own semantics.
            var startupRepairLock: RegistrationRepairLock.Handle?
            // Drop this reference. That releases the lock unless a repair that
            // outran the wait is still running, which retains its own; the
            // descriptor closes when the last owner lets go.
            defer { startupRepairLock = nil }
            do {
                // Register the helper agent with launchd before the
                // first XPC send. Skipped under `--smoke` because
                // the hermetic gate has no SMAppService story and
                // any system-side state change would leak across
                // verify runs. Production launches always
                // register; the smoke gate exercises the UDS
                // fallback path instead. A throw here is
                // non-fatal; we fall through to the connect()
                // call and let the disabled-helper sheet surface
                // if the production connection fails.
                if !smokeMode {
                    // Finish an interrupted registration repair before anything
                    // registers or connects. A previous process may have been
                    // terminated between tearing the launchd job down and
                    // standing it back up, which leaves no helper at all;
                    // registering or connecting on top of that half-state would
                    // race a teardown that is still in flight. Bounded, because
                    // the replay is the same non-cancellable ServiceManagement
                    // call the ladder had to abandon, and a launch that waited
                    // on a stalled one would never reach a window.
                    //
                    // The lock is taken ONCE here and held through registration
                    // and the version handshake, not just across the
                    // reconciliation. Releasing it at the end of the
                    // reconciliation would leave a gap in which another copy of
                    // DeviceTerm could take it and begin a teardown, and this
                    // launch would then register and connect over an active
                    // repair, which is the state the lock exists to rule out.
                    switch await acquireStartupRepairLock() {
                    case let .acquired(held):
                        startupRepairLock = held

                    case let .surrender(situation):
                        presentUpdateRestart(situation)
                        return
                    }
                    if let stall = await reconcileInterruptedRepair(
                        holding: startupRepairLock
                    ) {
                        presentUpdateRestart(stall)
                        return
                    }
                    try? DaemonRegistration.registerOnFirstLaunch()
                    // Drive inventory re-supply on every reconnect (a daemon-only
                    // restart while the GUI stays alive) through the coordinator.
                    // Skipped under `--smoke`: the UDS fallback can't carry the
                    // `.validatedGUI` `session.restoreBatch`, so daemon-restart
                    // recovery is an XPC-only feature there.
                    daemonClient.onReconnected = { [weak self] in
                        guard let self else { return }
                        // Before the re-supply, so the owned-sim mirror stops
                        // believing roster reads the moment a new connection is
                        // live. It may or may not reach a fresh helper, and a
                        // fresh one answers that it owns nothing, so the mirror
                        // ignores those reads until the (idempotent)
                        // re-assertion completes. The app-wide poll keeps running and
                        // discovery keeps using them; it is only the mirror
                        // that holds off. The mirror is all recovery has for
                        // the sims a pane isn't carrying. The transport's own counter, the
                        // one `deviceListWithGeneration` returns; the handshake
                        // counter beside it trails by a scheduling hop and
                        // numbers connections differently.
                        self.router.noteConnectionReplaced(
                            generation: self.daemonClient.connectionGeneration
                        )
                        self.inventorySync.reconnected(
                            generation: self.daemonClient.reconnectGeneration
                        )
                    }
                    // A helper that has stopped answering leaves tabs,
                    // windows, and panes stuck with no in-app way out. Offer
                    // the restart that fixes it. Skipped under `--smoke`,
                    // where a modal would stall the gate and there is no XPC
                    // peer to stop anyway.
                    daemonClient.onUnresponsive = { [weak self] connection in
                        self?.helperRecovery.helperStoppedAnswering(connection: connection)
                    }
                    // A MID-SESSION wire-version mismatch: an auto-reconnect
                    // landed on a daemon replaced by an incompatible build. This
                    // path deliberately does not recover, because live panes and
                    // sessions are at stake and the user should choose when to
                    // take the hit. An acknowledgement proves only that shutdown
                    // was accepted; a missing one leaves helper state unknown.
                    daemonClient.onVersionMismatch = { [weak self] outcome in
                        self?.presentUpdateRestart(versionMismatchSituation(from: outcome))
                    }
                }
                try await connectRecoveringFromVersionMismatch(holding: startupRepairLock)
                // A compatible helper is answering, so the registration is
                // evidently intact and the critical section is over. Dropping
                // the reference is the release, unless a background repair still
                // holds it.
                startupRepairLock = nil
                connected = true
                // Release the daemon's restoration barrier on this first
                // connect too: a fresh cold-start daemon holds no session, and
                // the GUI has no tabs yet, so this sends an empty
                // `restoreBatch`, promptly flipping any stale unknown-session
                // authenticate from retryable to terminal instead of leaving it
                // to exhaust its retry budget. The coordinator sends it in the
                // background so window mount is never blocked; on a fresh daemon
                // the empty batch succeeds at once. Every later workspace change
                // re-supplies the inventory (see `markInventoryDirtyIfChanged`),
                // and reconnects re-supply via `onReconnected`. Skipped under
                // smoke (UDS can't carry `.validatedGUI` `restoreBatch`).
                if !smokeMode {
                    inventorySync.markDirty()
                }
                // Begin draining the back-channel before the first
                // window mounts so an immediate CLI verb (`deviceterm tab
                // open` issued during launch) lands on a live drain.
                // The subscriber re-establishes on transport drops. A live
                // connection that has simply stopped answering parks the
                // handshake instead, until it replies or the connection goes
                // away (see `DaemonClient.subscribeAppCommands`).
                appCommandSubscriber.start()
                let orphansToReattach = await recoverOrphansIfNeeded()
                observation = App.observe { [weak self] in self?.reconcileWindows() }
                // Re-supply the daemon's authoritative inventory whenever the
                // live session set changes, so a closed session's tombstone is
                // reclaimed promptly rather than accumulating until a reconnect.
                if !smokeMode {
                    inventoryObservation = App.observe { [weak self] in
                        self?.markInventoryDirtyIfChanged()
                    }
                }
                // Boot-time orphan flow carries `[OrphanRecord]` on
                // the route, a shape no external intent can express.
                // Keep this Router-direct; user-input @objc paths
                // (`newWindow`, dock-reopen) go through the
                // dispatcher.
                // A first-run welcome is a launch gate: it comes up
                // before the first DeviceTerm window, so it can't be
                // buried by the app it is explaining, and the window
                // opens when it's dismissed. The completion runs
                // immediately when no welcome is due, so the window
                // opens exactly once on every path.
                //
                // Skipped under `--smoke`: the hermetic gate asserts on
                // a known window set, and it must not wait on a click.
                if smokeMode {
                    router.dispatch(.openWindow(reattach: orphansToReattach))
                    runSmokeCheck()
                } else {
                    WelcomeCoordinator.shared.presentIfNeeded { [weak self] in
                        self?.router.dispatch(.openWindow(reattach: orphansToReattach))
                    }
                }
            } catch let surrender as StartupVersionSurrender {
                // Recovery ran and could not replace the helper. It has already
                // fenced the transport; all that is left is to say so.
                presentUpdateRestart(surrender.situation)
            } catch let error as DaemonClientError where error.isVersionMismatch {
                // Smoke mode only: it has no recovery ladder (UDS can't request
                // a shutdown), so the raw mismatch reaches here. Production
                // startup mismatches leave through the surrender above.
                if smokeMode { smokeFail("daemon wire-version mismatch: \(error)") }
            } catch {
                if smokeMode { smokeFail("could not start deviceterm: \(error)") }
                // An enabled registration plus an unreachable helper may be
                // repairable by re-registration, and a dead app gives the user
                // no route to it, so offer that option before quitting.
                if let clientError = error as? DaemonClientError,
                    RegistrationRepairDecision.evaluate(
                        failure: clientError,
                        status: DaemonRegistration.status,
                        isSmokeMode: smokeMode
                    ) == .offerRepair {
                    guard let startupRepairLock else {
                        fail(
                            "Could not repair the deviceterm helper's registration: "
                                + "the startup repair lock is not held"
                        )
                        return
                    }
                    await offerRegistrationRepair(
                        after: clientError,
                        holding: startupRepairLock
                    )
                    return
                }
                fail("Could not start deviceterm: \(error)")
            }
        }
    }

    /// Offer to re-register the helper agent, then quit either way.
    ///
    /// Quitting is the design, not a shortfall. A fresh process IS the
    /// connection reset, so nothing here has to coordinate with the machinery a
    /// second in-process attempt would wake: no reconnect callback fires on a
    /// replacement peer, no second bounded ping expires into a health probe
    /// that races `HelperRecoveryCoordinator`'s own restart prompt, and no
    /// peer left installed by a timed-out handshake can be silently reused. It
    /// also matches the remediation the version-mismatch path already gives.
    ///
    /// No daemon call follows a successful repair; the next launch creates a
    /// fresh connection.
    private func offerRegistrationRepair(
        after failure: DaemonClientError,
        holding lock: RegistrationRepairLock.Handle
    ) async {
        registrationLog.notice(
            """
            helper unreachable at launch (\(failure.description, privacy: .public)) \
            while its registration reads enabled; offering to re-register
            """
        )
        let alert = NSAlert()
        alert.messageText = "Repair the deviceterm helper's registration?"
        alert.informativeText = """
            The helper is registered, but DeviceTerm could not reach it. \
            Re-registering may clear a stale registration. If the helper is \
            running but slow to answer, repairing stops it: simulators keep \
            running, DeviceTerm forgets which ones it booted, and \
            physical-device mirroring stops. DeviceTerm quits either way, \
            because it could not reach the helper. (\(failure.description))
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Repair and Quit")
        alert.addButton(withTitle: "Quit Without Repair")
        guard alert.runModal() == .alertFirstButtonReturn else {
            registrationLog.notice("re-registering declined; quitting")
            NSApp.terminate(nil)
            return
        }
        // Re-read the status because the repair should remain available only
        // while the registration is enabled: the user could have enabled or
        // disabled the login item in System Settings while the alert was open.
        guard RegistrationRepairDecision.evaluate(
            failure: failure,
            status: DaemonRegistration.status,
            isSmokeMode: smokeMode
        ) == .offerRepair else {
            fail("""
                The helper's registration changed while the prompt was open, so \
                DeviceTerm left it alone. Reopen DeviceTerm to try again. \
                (\(failure.description))
                """)
            return
        }
        do {
            let store = try RegistrationRepairStore.standard()
            // Startup already owns the lock across registration and the
            // handshake. A second flock on a new descriptor contends even in
            // this process, so the consented repair must reuse that handle.
            try await DaemonRegistration.repair(store: store, holding: lock)
        } catch {
            // The repair error, not the connection failure that prompted it:
            // the user asked for this action specifically, so what they need is
            // why it did not happen.
            registrationLog.error(
                """
                re-registering the agent failed: \
                \(String(describing: error), privacy: .public)
                """
            )
            fail("Could not repair the deviceterm helper's registration: \(error)")
            return
        }
        registrationLog.notice("re-registered the agent; quitting for a fresh launch")
        let done = NSAlert()
        done.messageText = "The deviceterm helper's registration was repaired"
        done.informativeText = "Reopen DeviceTerm to connect to the helper."
        done.alertStyle = .informational
        done.addButton(withTitle: "Quit")
        done.runModal()
        NSApp.terminate(nil)
    }

    /// Connect, recovering silently from a startup wire-version mismatch.
    ///
    /// After a Sparkle update the running helper is the old one while the bundle
    /// on disk is new. At this point in launch the GUI holds no window, session,
    /// pane, or subscription, so this GUI has no state at risk, though another
    /// running checkout can lose its helper to the same swap. Only when the
    /// ladder cannot get a matching helper answering does anything reach the
    /// screen.
    ///
    /// Smoke mode is excluded deliberately: its UDS transport cannot carry a
    /// `.validatedGUI` `daemon.shutdown`, so it has no first rung, and the
    /// hermetic gate asserts on the raw mismatch instead.
    private func connectRecoveringFromVersionMismatch(
        holding lock: RegistrationRepairLock.Handle?
    ) async throws {
        do {
            try await daemonClient.connect()
        } catch let error as DaemonClientError where error.isVersionMismatch && !smokeMode {
            let coordinator = WireVersionRecoveryCoordinator(
                versionRecoveryDependencies(holding: lock)
            )
            switch await coordinator.recover(after: error) {
            case .connected:
                return

            case let .surrender(situation):
                throw StartupVersionSurrender(situation: situation)
            }
        }
    }

    /// Take the repair lock for the startup critical section.
    ///
    /// Polls rather than blocking, so another process's stuck repair cannot park
    /// this launch indefinitely. Giving up surrenders rather than proceeding:
    /// the whole point of the lock is that registering or connecting past an
    /// active repair is the thing to avoid.
    private func acquireStartupRepairLock() async -> StartupLockAcquisition {
        let store: RegistrationRepairStore
        do {
            store = try RegistrationRepairStore.standard()
        } catch {
            let reason = "DeviceTerm could not reach the folder holding its helper state"
            registrationLog.error(
                "could not resolve the repair lock: \(ErrorText.describing(error), privacy: .public)"
            )
            return .surrender(
                UpdateRestartSituation(
                    cause: .registrationStateUnknown(reason),
                    detail: "\(reason)\n\(ErrorText.describing(error))"
                )
            )
        }
        let deadline = Date().addingTimeInterval(startupRepairLockWaitSeconds)
        while true {
            do {
                if let held = try RegistrationRepairLock.tryAcquire(at: store.lockPath) {
                    return .acquired(held)
                }
            } catch {
                // The lock file is unusable, which is a different problem from
                // someone holding it and must not be reported as waiting one out.
                let reason = ErrorText.describing(error)
                return .surrender(
                    UpdateRestartSituation(
                        cause: .registrationStateUnknown(reason),
                        detail: reason
                    )
                )
            }
            guard Date() < deadline else {
                // Deliberately hedged: the holder may be repairing, or may just
                // be another copy starting up and holding this across its own
                // handshake. Claiming a repair outright would often be wrong.
                let busy = "another copy of DeviceTerm is starting up and may be "
                    + "rebuilding the helper's registration"
                registrationLog.notice("startup repair lock is held elsewhere; giving up")
                return .surrender(
                    UpdateRestartSituation(
                        cause: .registrationRepairStalled(busy),
                        detail: busy
                    )
                )
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Finish a registration repair an earlier process was terminated in the
    /// middle of, returning a situation to surface if the replay stalls.
    ///
    /// Bounded for the same reason the ladder's own repair rung is: the replayed
    /// `unregister()` is not cancellable, so a launch that awaited a stuck one
    /// would never reach a window, and would repeat that on every relaunch with
    /// nothing on screen to explain it. The replay keeps running either way and
    /// clears the marker if it gets there.
    private func reconcileInterruptedRepair(
        holding lock: RegistrationRepairLock.Handle?
    ) async -> UpdateRestartSituation? {
        let store: RegistrationRepairStore
        do {
            store = try RegistrationRepairStore.standard()
        } catch {
            // Fail closed. Resolving this may have succeeded on the launch that
            // wrote a marker and be failing only now, so "no location" is not
            // evidence that no repair is pending. It also means a repair cannot
            // be run, so there is no way to find out.
            let reason = "DeviceTerm could not reach the folder holding its helper state"
            registrationLog.error(
                """
                could not resolve the registration-repair marker: \
                \(ErrorText.describing(error), privacy: .public)
                """
            )
            return UpdateRestartSituation(
                cause: .registrationStateUnknown(reason),
                detail: "\(reason)\n\(ErrorText.describing(error))"
            )
        }
        let reconciler = InterruptedRepairReconciler(
            InterruptedRepairReconciler.Dependencies(
                // The lock is already held by the launch, so the reconciler
                // reuses it rather than taking a second one: `flock` is per open
                // file description, so a second acquisition inside this process
                // would fail against our own hold.
                heldLock: lock,
                isRepairUnderway: { try store.isRepairUnderway() },
                repair: { held in
                    try await DaemonRegistration.repair(store: store, holding: held)
                },
                sleep: { try? await Task.sleep(nanoseconds: $0) }
            )
        )
        switch await reconciler.reconcile() {
        case .nothingToDo:
            return nil

        case .reconciled:
            registrationLog.notice("finished a registration repair left by an earlier launch")
            return nil

        case let .surrender(situation):
            registrationLog.error("registration repair could not be completed")
            return situation
        }
    }

    /// Dependencies for the recovery ladder, all resolved against this
    /// delegate's live client. Assembled here so the coordinator itself stays
    /// free of AppKit, launchd, and a real clock.
    private func versionRecoveryDependencies(
        holding lock: RegistrationRepairLock.Handle?
    ) -> WireVersionRecoveryCoordinator.Dependencies {
        WireVersionRecoveryCoordinator.Dependencies(
            pinnedToIncompatibleHelper: { [daemonClient] in daemonClient.isRecoveryPinned },
            requestShutdown: { [daemonClient] in await daemonClient.requestIncompatibleShutdown() },
            terminateHelper: { [daemonClient] in await daemonClient.terminateIncompatibleHelper() },
            repairRegistration: {
                // Reuses the lock the launch already holds. Acquiring a second
                // one here would fail against our own hold, because `flock` is
                // per open file description rather than per process.
                let store = try RegistrationRepairStore.standard()
                guard let held = lock else {
                    throw RegistrationRepairFailure(
                        unregistered: false,
                        underlying: RegistrationRepairLockError.cannotLock(
                            "the startup repair lock is not held"
                        )
                    )
                }
                try await DaemonRegistration.repair(store: store, holding: held)
            },
            handshake: { [daemonClient] in await daemonClient.recoveryHandshake() },
            finishRecovery: { [daemonClient] in await daemonClient.leaveVersionRecovery() },
            abandonRecovery: { [daemonClient] in await daemonClient.abandonVersionRecovery() },
            sleep: { try? await Task.sleep(nanoseconds: $0) }
        )
    }

    /// Surface a restart request.
    ///
    /// Routed through the Quit-only failure alert, which is honest for every
    /// cause this can carry: none of them is improved by a button offering to
    /// relaunch straight back into the same state.
    private func presentUpdateRestart(_ situation: UpdateRestartSituation) {
        fail(restartPlainText(for: situation))
    }

    /// Mark the daemon's session inventory dirty when the live session SET
    /// changes (a terminal opened or closed), so the `InventorySyncCoordinator`
    /// re-supplies the authoritative inventory. This is what reclaims a closed
    /// session's daemon tombstone promptly (an omitting inventory) instead of
    /// letting it accumulate until a reconnect. Runs from an `App.observe`
    /// closure, so it reads every terminal's `sessionId` on each pass (the
    /// observation contract); the `lastInventorySessionIDs` guard suppresses
    /// re-supply on changes that don't move the session set (window geometry,
    /// selection, a protection toggle, which `session.setProtectedBatch` owns).
    private func markInventoryDirtyIfChanged() {
        let current = Set(
            workspace.windows.flatMap(\.tabs.tabs)
                .flatMap { $0.terminals.map(\.sessionId) }
                .filter { !$0.isEmpty }
        )
        guard current != lastInventorySessionIDs else { return }
        lastInventorySessionIDs = current
        inventorySync.markDirty()
    }

    /// Close any session that was restored but is no longer backed by a live
    /// terminal in the workspace (closed during the restore window). The GUI's
    /// validated XPC connection spans sessions, so it may close a session it
    /// does not hold as its own authenticated one.
    @MainActor
    private func closeGhostSessions(restored: [RestoredSession]) async {
        let live = Set(
            workspace.windows.flatMap(\.tabs.tabs).flatMap { $0.terminals.map(\.sessionId) }
        )
        for entry in restored where !live.contains(entry.sessionId) {
            try? await daemonClient.closeSession(
                sessionId: entry.sessionId,
                capability: entry.capability,
                mode: .detach
            )
        }
    }

    /// Self-check fired by `--smoke` once the first window is up. Drives
    /// the Router paths (newTab / closeTab / openWindow /
    /// closeWindow) by dispatching routes and reading nav state, so the
    /// gate catches regressions in the unidirectional path without
    /// needing a human.
    private func runSmokeCheck() {
        Task { @MainActor in
            // Stage 1: first window + initial tab (Router.openWindow).
            let tabCtl = await waitForFirstTab(timeoutSeconds: 5)
            guard tabCtl != nil else {
                smokeFail("first tab did not appear within 5s")
            }
            // Stage 2: a daemon round-trip on the live connection.
            do {
                _ = try await daemonClient.deviceList(scope: .all)
            } catch {
                smokeFail("daemon round-trip failed: \(error)")
            }
            guard let windowID = workspace.selectedWindowID else {
                smokeFail("no selected window after open")
            }
            // Stage 3: newTab route → tab count reaches 2. Driven
            // through the @objc menu path (TabStripVC.newTab) so the
            // smoke gate covers the dispatcher wiring end-to-end;
            // a regression in the menu → IntentDispatcher → Router
            // chain surfaces here instead of waiting for a manual
            // walkthrough.
            tabCtl?.newTab(nil)
            guard await waitForTabCount(2, in: windowID, timeoutSeconds: 5) else {
                smokeFail("newTab did not increase tab count to 2")
            }
            // Stage 4: closeTab route on the second tab → count back to 1.
            guard let secondTabID = workspace.window(id: windowID)?
                .tabs.tabs.last?.id else {
                smokeFail("no second tab to close")
            }
            router.dispatch(.closeTab(windowID, secondTabID, mode: .detach))
            guard await waitForTabCount(1, in: windowID, timeoutSeconds: 5) else {
                smokeFail("closeTab did not reduce tab count to 1")
            }
            // Stage 5: openWindow → second window appears and is selected.
            router.dispatch(.openWindow())
            guard await waitForWindowCount(2, timeoutSeconds: 8) else {
                smokeFail("openWindow did not create a second window")
            }
            guard let secondWindowID = workspace.selectedWindowID,
                secondWindowID != windowID else {
                smokeFail("second window not selected after openWindow")
            }
            // Stage 6: selectWindow back to the first → selection flips.
            router.dispatch(.selectWindow(windowID))
            guard await waitForSelectedWindow(windowID, timeoutSeconds: 3) else {
                smokeFail("selectWindow did not flip selection back")
            }
            // Stage 7: closeWindow on the second → window count back to 1.
            router.dispatch(.closeWindow(secondWindowID, mode: .detach))
            guard await waitForWindowCount(1, timeoutSeconds: 5) else {
                smokeFail("closeWindow did not drop to 1 window")
            }
            // NOTE: the Detach/Shut-Down NSAlert prompt, the pane shutdown
            // overlay (needs a real booted sim), the status-item count
            // (lives in the daemon's NSStatusItem), and the ⌘Q quit-with-
            // sims sheet are deliberately NOT covered here; they need UI
            // automation or live sims, which the no-XCTest gate avoids.
            // Those flows live in Tests/Manual.
            FileHandle.standardOutput.write(Data("smoke: ok\n".utf8))
            exit(0)
        }
    }

    private func waitForTabCount(
        _ count: Int,
        in windowID: WindowID,
        timeoutSeconds: Double
    ) async -> Bool {
        await pollState(timeoutSeconds: timeoutSeconds) { [weak self] in
            self?.workspace.window(id: windowID)?.tabs.tabs.count == count
        }
    }

    private func waitForWindowCount(
        _ count: Int,
        timeoutSeconds: Double
    ) async -> Bool {
        await pollState(timeoutSeconds: timeoutSeconds) { [weak self] in
            self?.workspace.windows.count == count
        }
    }

    private func waitForSelectedWindow(
        _ windowID: WindowID,
        timeoutSeconds: Double
    ) async -> Bool {
        await pollState(timeoutSeconds: timeoutSeconds) { [weak self] in
            self?.workspace.selectedWindowID == windowID
        }
    }

    private func pollState(
        timeoutSeconds: Double,
        predicate: @MainActor () -> Bool
    ) async -> Bool {
        let stepNs: UInt64 = 100_000_000
        let deadlineNs = UInt64(timeoutSeconds * 1_000_000_000)
        var elapsedNs: UInt64 = 0
        while elapsedNs < deadlineNs {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: stepNs)
            elapsedNs += stepNs
        }
        return false
    }

    private func waitForFirstTab(timeoutSeconds: Double) async -> TabStripViewController? {
        let deadlineNs = UInt64(timeoutSeconds * 1_000_000_000)
        let stepNs: UInt64 = 100_000_000
        var elapsedNs: UInt64 = 0
        while elapsedNs < deadlineNs {
            if let windowCtl = windowControllerByID.values.first,
                let tabCtl = windowCtl.contentViewController as? TabStripViewController,
                tabCtl.tabCount >= 1 {
                return tabCtl
            }
            try? await Task.sleep(nanoseconds: stepNs)
            elapsedNs += stepNs
        }
        return nil
    }

    private func smokeFail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("smoke: \(message)\n".utf8))
        exit(1)
    }

    /// Shut a sim down and drop the owned-sim mirror's claim on success. The
    /// daemon disowns it as part of the shutdown, and a claim left standing is
    /// one recovery would re-assert against a sim something else may have
    /// booted since.
    private func shutdownAndForget(udid: String) async {
        guard (try? await daemonClient.shutdownDevice(udid: udid)) != nil else { return }
        router.noteSimShutdown(udid: udid)
    }

    private func recoverOrphansIfNeeded() async -> [OrphanRecord] {
        let devices = (try? await daemonClient.deviceList(scope: .all)) ?? []
        let (live, dead) = OrphanRecovery.collect(deviceList: devices)
        OrphanRecovery.cleanup(dead)
        guard !live.isEmpty else { return [] }
        switch OrphanRecovery.runSheet(for: live) {
        case .reattach:
            return live

        case .shutdownAll:
            for sim in live.flatMap(\.liveSims) {
                await shutdownAndForget(udid: sim.udid)
            }
            OrphanRecovery.cleanup(live.map(\.sessionDir))
            return []

        case .leaveRunning:
            return []
        }
    }

    // MARK: - Quit (preserves `.terminateLater` await-before-exit)

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Stop proposing a restart: quit is itself the escape from a wedged
        // helper, and this path is where the calls that would diagnose one
        // pile up (the owned-device check, then every window's pane and
        // session teardown, each carrying its own bound). A modal raised now
        // would sit in front of the quit the user already asked for, while
        // `.terminateLater` waits behind it. Cleared rather than gated on a
        // flag so there is nothing left to fire; no path here declines the
        // termination.
        daemonClient.onUnresponsive = nil
        let liveIDs = workspace.windows.map(\.id)
        if liveIDs.isEmpty { return .terminateNow }
        Task { @MainActor in
            // Prompt only if deviceterm-owned sims are actually booted.
            var mode: PaneCloseMode = .detach
            let owned = (try? await daemonClient.deviceList(scope: .owned)) ?? []
            let booted = owned.filter { $0.state == "Booted" }
            if !booted.isEmpty {
                let quit = CloseDecisions.quitWithSims(
                    config: ConfigFile(),
                    state: CloseSuppressionState.shared
                )
                if quit == .shutdownSims {
                    mode = .shutdown
                }
            }
            // Dispatch closeWindow per window with the user-chosen mode;
            // the Router fans out per-tab pane.close + session.close +
            // (on .shutdown) the device.shutdown loop + dir cleanup.
            //
            // Stays on Router-direct: this is an internal iteration
            // over every live window's concrete WindowID, not a
            // user-input verb targeting a ref. The dispatcher's
            // resolver only models `current` / `index` / `keyed` for
            // windows, which can't address "the window I'm
            // iterating to right now."
            for windowID in liveIDs {
                router.dispatch(.closeWindow(windowID, mode: mode))
            }
            // Stop the back-channel drain before tearing down the
            // daemon connection so a stray inbound AppCommand doesn't
            // race the dying window controllers.
            appCommandSubscriber.stop()
            await router.shutdown()
            // Local teardown happens here, NOT through reconcileWindows():
            // the Observation re-arm schedules the next reconcile on a
            // later main-actor turn that won't run before NSApp.reply()
            // tears the process down, so libghostty surfaces / discovery
            // polls / PaneResurrect watches would otherwise outlive quit.
            for (_, windowCtl) in windowControllerByID {
                (windowCtl.contentViewController as? TabStripViewController)?.teardown()
                windowCtl.window?.close()
            }
            windowControllerByID.removeAll()
            closingWindowIDs.removeAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool { false }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        // A first-run welcome is a launch gate: the first window opens
        // when it is dismissed. While it's up there are no window
        // controllers yet, so without this the Dock click below would
        // open a window behind it and the gate's completion would then
        // open a second one.
        if WelcomeCoordinator.shared.isGatingLaunch {
            WelcomeCoordinator.shared.bringToFront()
            return false
        }
        if windowControllerByID.isEmpty, connected {
            dispatchIntent(.openWindow)
            return false
        }
        return true
    }

    /// User clicked the window's close affordance (red X / ⌘W on the
    /// last tab). Mirrors the tab-close prompts for the window scope:
    /// ask whether to detach (keep sims running) or shut them down
    /// when any of this window's tabs own a booted sim, and confirm
    /// the close when any tab holds more than one pane and the sim
    /// prompt isn't about to run (`TabCloseGateDecision`, the same
    /// gate as `requestCloseTab`). Cancel in either prompt aborts the
    /// close; chosen mode is stashed in `pendingCloseModeByID`
    /// and consumed by `windowWillClose`. Router-driven closes (the
    /// `closingWindowIDs` guard) skip the prompts; the upstream caller
    /// already chose the mode.
    ///
    /// Returns `false` synchronously and re-issues `window.close()`
    /// from the async path once the daemon-attribution lookup
    /// completes. The simpler `tab.simPanes` predicate would be wrong
    /// here for the same reason it's wrong in `requestCloseTab`: a
    /// detached pane (visual close) leaves the session as the sim's
    /// owner, so the prompt MUST consider session ownership, not
    /// pane visibility.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = windowControllerByID.first(where: { $0.value.window === sender })
        else { return true }
        let windowID = entry.key
        // Router-initiated close (CLI `deviceterm window close`, ⌘Q
        // teardown, reconcile drop) flagged this window before
        // calling `window.close()`. The upstream caller has
        // already chosen the mode; don't double-prompt.
        if closingWindowIDs.contains(windowID) {
            return true
        }
        // Re-entry from the async path's `sender?.close()`:
        // `pendingCloseModeByID` was set just before the call. Don't
        // spawn a duplicate Task; just let the close proceed.
        if pendingCloseModeByID[windowID] != nil {
            return true
        }
        // Sweep every terminal pane in every tab. closeTabRecords
        // shuts down devices owned by any of a tab's terminal
        // sessions, not just the primary, so the affected-check has
        // to match; otherwise a sim owned by a secondary terminal
        // would let the window close skip the prompt and force-detach.
        let sessionIDs = workspace.window(id: windowID)?.tabs.tabs
            .flatMap { $0.terminals.map(\.sessionId) }
            .filter { !$0.isEmpty } ?? []
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let affected = await self.daemonClient.hasOwnedBootedSims(
                forSessions: sessionIDs
            )
            // Re-read the window's tabs after the await: the main
            // actor yielded while the daemon answered, so the
            // multi-pane gate uses the current layout. The
            // sim-ownership answer still reflects the sessions
            // captured at the gesture.
            let tabs = self.workspace.window(id: windowID)?.tabs.tabs ?? []
            let multiPaneTabCount = tabs
                .filter { PaneTreeOps.leavesInOrder($0.paneTree).count > 1 }
                .count
            let tabCount = tabs.count
            let config = ConfigFile()
            let pinned = affected
                ? CloseSuppressionState.shared.lookupClose(
                    windowID: windowID,
                    config: config
                )
                : nil
            let mode: PaneCloseMode
            switch TabCloseGateDecision.gate(
                simsAffected: affected,
                pinnedSimDecision: pinned,
                multiPane: multiPaneTabCount > 0
            ) {
            case .simDisposition:
                let decision = await CloseDecisions.windowClose(
                    config: config,
                    state: CloseSuppressionState.shared,
                    windowID: windowID,
                    window: sender,
                    whileTargetLives: { [weak self] in
                        self?.workspace.window(id: windowID) != nil
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

            case let .multiPaneConfirm(gateMode):
                guard await CloseDecisions.multiPaneWindowClose(
                    config: config,
                    state: CloseSuppressionState.shared,
                    windowID: windowID,
                    tabCount: tabCount,
                    multiPaneTabCount: multiPaneTabCount,
                    window: sender,
                    whileTargetLives: { [weak self] in
                        self?.workspace.window(id: windowID) != nil
                    }
                ) else { return }
                mode = gateMode

            case let .close(gateMode):
                mode = gateMode
            }
            self.pendingCloseModeByID[windowID] = mode
            // Re-trigger close after the deferred decision. The
            // `pendingCloseModeByID` entry above short-circuits the
            // re-entry guard so we don't re-loop.
            sender?.close()
        }
        return false
    }

    /// AppKit made one of the workspace's windows key: mirror that into
    /// `selectedWindowID`. Nothing else observes a plain focus change,
    /// so without this the field goes stale the moment the human clicks
    /// another window: `windows.list` marks `isKey` on the window they
    /// left, and an in-process `.current` resolves against a window
    /// nobody is looking at.
    ///
    /// Recording the raise here is also why `focusWindow` doesn't
    /// enqueue a selection route: a route waits on the Router's serial
    /// drain and can land after a later click, overwriting a fresher
    /// answer. Structural paths do still set the selection directly
    /// (opening or closing a window, and a cross-window tab move
    /// choosing its destination), so this is the mirror for focus, not
    /// the field's only writer.
    ///
    /// The `windowControllerByID` lookup is also the filter: the
    /// welcome, About, settings-prompt, and device-picker windows aren't
    /// in the map, so one of them taking key doesn't move the workspace
    /// selection to nothing. It guards the focus repair below too.
    ///
    /// The selection write is conditional but the focus repair is not:
    /// returning to the app you already had selected is the common
    /// ⌘Tab-back case, and it is exactly where an orphaned first
    /// responder needs repairing.
    ///
    /// Repairing synchronously assumes this notification arrives before
    /// the activating click's `mouseDown`. On that ordering a pane that
    /// kept focus reads as non-orphaned and is left alone, and a
    /// genuinely orphaned tab is restored here and then superseded by
    /// the click's own `makeFirstResponder` if it landed on another
    /// pane. Deferring a runloop turn would land after the click and
    /// take focus back off it.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let entry = windowControllerByID.first(where: { $0.value.window === window })
        else { return }
        if workspace.selectedWindowID != entry.key {
            workspace.select(id: entry.key)
        }
        strip(for: entry.key)?.restoreFocusIfOrphaned()
    }

    /// Window is definitely closing now. Drop the WC from the map
    /// *synchronously* (so a Dock reopen during the Router's async
    /// teardown sees an empty app) and dispatch closeWindow with the
    /// disposition `windowShouldClose` chose; the Router cleans up
    /// the daemon sessions + nav state.
    ///
    /// `closeWindow` keeps targeting a concrete `WindowID` (the
    /// closing window isn't guaranteed to be the key window; AppKit
    /// can close a background window via scripting / private API),
    /// so it stays on Router rather than going through the intent
    /// layer's resolver. The user-input verbs that DO go through the
    /// dispatcher (`newWindow`, `applicationShouldHandleReopen`'s
    /// re-open) target "no specific window" / "current."
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let entry = windowControllerByID.first(where: { $0.value.window === window })
        else { return }
        let windowID = entry.key
        let windowCtl = entry.value
        // `windowShouldClose` stashed the mode it resolved for a
        // user-initiated close; if it didn't run (Router-driven
        // teardown), default to `.detach`, a no-op when nothing's
        // running, and the safer choice if a sim slipped through the
        // predicate.
        let mode = pendingCloseModeByID.removeValue(forKey: windowID) ?? .detach
        // Tear down before dropping the WC so the per-tab cleanup runs
        // (observation, discovery observer, terminal.requestClose, PaneResurrect
        // unwatch); releasing the WC alone would leak those.
        (windowCtl.contentViewController as? TabStripViewController)?.teardown()
        windowControllerByID.removeValue(forKey: windowID)
        closingWindowIDs.insert(windowID)
        router.dispatch(.closeWindow(windowID, mode: mode))
    }

    @objc
    func newWindow(_ sender: Any?) {
        guard connected, !welcomeIsGatingLaunch() else { return }
        dispatchIntent(.openWindow)
    }

    /// Responder-chain fallback: ⌘T with no key window.
    @objc
    func newTab(_ sender: Any?) {
        guard connected, !welcomeIsGatingLaunch() else { return }
        dispatchIntent(.openWindow)
    }

    /// Whether a first-run welcome is holding the launch sequence. The
    /// gate opens the first window itself when the welcome closes, so
    /// any other route to `.openWindow` has to stand down or the app
    /// ends up with two. Surfaces the welcome rather than doing nothing
    /// silently, so a ⌘N that appears ignored still explains itself.
    private func welcomeIsGatingLaunch() -> Bool {
        guard WelcomeCoordinator.shared.isGatingLaunch else { return false }
        WelcomeCoordinator.shared.bringToFront()
        return true
    }

    /// Fire-and-forget dispatcher shape for the AppKit @objc menu /
    /// callback handlers. Mirrors `TabStripViewController`'s
    /// `dispatchIntent` so the menu / strip surfaces share one path
    /// to the intent layer.
    private func dispatchIntent(_ intent: RouteIntent) {
        let dispatcher = intentDispatcher
        Task { _ = await dispatcher.dispatch(intent, origin: .inProcess) }
    }

    // MARK: - App + Help menu actions

    /// deviceterm > Settings…: open the config file in a new terminal tab
    /// running `$EDITOR`. When the file is missing, the view model puts
    /// up a SwiftUI create-confirmation first.
    @objc
    func openSettings(_ sender: Any?) {
        // With no window open, `openConfigEditorTab` dispatches
        // `.openWindow` directly, which during the first-run gate would
        // put a window up behind the welcome and leave a second one to
        // arrive when it closes.
        guard !welcomeIsGatingLaunch() else { return }
        let configPath = ConfigFile.defaultPath
        let viewModel = ConfigSettingsViewModel(
            configPath: configPath,
            openInEditorTab: { [weak self] in
                self?.openConfigEditorTab(configPath: configPath)
            },
            onPromptResolved: { [weak self] in
                self?.settingsPromptWC?.close()
                self?.settingsPromptWC = nil
            }
        )
        viewModel.open()
        guard viewModel.isConfirmingCreate else { return }
        let promptWC = SettingsPromptWindowController(viewModel: viewModel)
        settingsPromptWC = promptWC
        promptWC.showPrompt()
    }

    /// Shell > Mirror Physical Device…: open the device picker. On
    /// pick, dispatch `Route.attachDevicePane` against the invoking
    /// window's active tab (the picker is the GUI trigger for the same
    /// attach the CLI / shim reach later). The window's single shared
    /// daemon connection authenticates to the active session, and the
    /// Router threads the tab's session explicitly, the trusted-GUI
    /// attribution the daemon honors.
    ///
    /// The target **window** is resolved from the key `NSWindow` here,
    /// at menu-invocation time, and must be captured now, before the
    /// picker opens and steals key. `workspace.selectedWindowID` is the
    /// fallback for when no window in the map holds key; it carries the
    /// workspace selection, which focus changes mirror in but
    /// structural ones set outright, so the live `NSApp.keyWindow` read
    /// stays the primary. The **tab** within that window is resolved at
    /// *selection* time so it stays current if the user switches tabs
    /// while the picker is up.
    @objc
    func mirrorPhysicalDevice(_ sender: Any?) {
        let targetWindowID = windowControllerByID
            .first { $0.value.window === NSApp.keyWindow }?.key
            ?? workspace.selectedWindowID
        let viewModel = DevicePickerViewModel(
            daemon: daemonClient,
            attach: { [weak self] deviceId, displayName in
                guard let self,
                    let windowID = targetWindowID,
                    let tab = self.workspace.window(id: windowID)?.tabs.selectedTab
                else { return }
                self.router.dispatch(
                    .attachDevicePane(
                        tab: tab.id,
                        deviceId: deviceId,
                        displayName: displayName
                    )
                )
                self.dismissDevicePicker()
            },
            dismiss: { [weak self] in
                self?.dismissDevicePicker()
            }
        )
        let pickerWC = DevicePickerWindowController(viewModel: viewModel)
        devicePickerWC = pickerWC
        pickerWC.showPicker()
        Task { await viewModel.load() }
    }

    private func dismissDevicePicker() {
        devicePickerWC?.close()
        devicePickerWC = nil
    }

    /// App menu > Restart Helper…: the same restart the unresponsive prompt
    /// offers, reachable deliberately. Recovery must not depend on the
    /// automatic prompt being up at the right moment, or on the user having
    /// left it up.
    @objc
    func restartHelper(_ sender: Any?) {
        helperRecovery.restartRequested()
    }

    /// Ask whether to restart the helper. Runs modally, so the choice is back
    /// before this returns.
    ///
    /// The message text is the question rather than the app name, because
    /// NSAlert renders it as the headline and this alert asks for a decision:
    /// a user glancing at it needs to read what they are being asked.
    ///
    /// The copy promises only what a restart actually recovers. Terminal
    /// panes are libghostty surfaces in this process and are not touched by
    /// any of this; simulators keep running because nothing here shuts one
    /// down; device panes reattach because the reconnect drives it. Panes
    /// that can't reattach are named too, since that is the outcome the user
    /// would otherwise read as the feature not working.
    private func promptForHelperRestart(
        _ reason: HelperRestartReason
    ) -> HelperRestartChoice {
        let alert = NSAlert()
        let recovery = "Simulators keep running and terminals are untouched. "
            + "Device panes reattach on their own; one that fails shows the "
            + "error in its own slot with a Retry button."
        switch reason {
        case .unresponsive:
            alert.messageText = "Several deviceterm helper requests timed out"
            alert.informativeText = "Tabs, windows, and device panes may be "
                + "stuck. " + recovery
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Restart Helper")
            alert.addButton(withTitle: "Keep Waiting")
            return alert.runModal() == .alertFirstButtonReturn ? .restart : .keepWaiting

        case .requested:
            alert.messageText = "Restart the deviceterm helper?"
            alert.informativeText = recovery
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Restart Helper")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .restart : .cancel
        }
    }

    /// Report an outcome that didn't confirm a stop: the signal was refused,
    /// or XPC exposed no peer process to send one to. The rest don't reach
    /// here, because they leave recovery free to carry on.
    ///
    /// The two that do reach here need different remedies, which is why the
    /// copy isn't shared. A refused signal means the helper is still running
    /// and this GUI can't stop it: quitting wouldn't help, because the helper
    /// is a launchd agent that outlives the GUI on purpose (it holds booted
    /// Simulators and the status item) and a wedged one isn't running its own
    /// idle-exit check either, so logging out is the honest remedy and the one
    /// the incompatible-helper alert already gives. An unreported peer is the
    /// opposite situation: the connection is open but names no process, so
    /// there may be nothing running to clear, and telling the user to log out
    /// over it would be advice about a problem they may not have.
    private func reportHelperRestartFailure(_ outcome: HelperTerminationOutcome) {
        let detail: String
        switch outcome {
        case let .failed(reason):
            detail = "The system refused to stop it (\(reason)). Logging out "
                + "and back in clears it."

        case .unknownPeer:
            detail = "macOS didn't report a process ID for the connection, "
                + "so deviceterm couldn't send it a signal. Try again in a "
                + "moment; if it keeps happening, quit and reopen deviceterm."

        case .terminated, .alreadyGone, .alreadyRestarted:
            return
        }
        let alert = NSAlert()
        alert.messageText = "Couldn't restart the deviceterm helper"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Help > Third-Party Notices: show (or re-front) the notices window.
    @objc
    func openThirdPartyNotices(_ sender: Any?) {
        if thirdPartyNoticesWC == nil {
            thirdPartyNoticesWC = ThirdPartyNoticesWindowController()
        }
        thirdPartyNoticesWC?.showWindow(nil)
        thirdPartyNoticesWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Help > Working with Apple's Simulator: show (or re-front) the
    /// coexistence welcome. Deliberately ungated, unlike the launch
    /// path: it opens whether or not the welcome has been seen and
    /// whether or not `welcome-messages` is suppressed, because the user
    /// asked for it by name. It still records the id and sets the
    /// per-launch latch.
    @objc
    func openSimulatorCoexistenceWelcome(_ sender: Any?) {
        WelcomeCoordinator.shared.present(id: WelcomeCatalog.simulatorCoexistenceID)
    }

    /// Gate the one app-menu item that can be dispatched into a dead end.
    ///
    /// The app menu leaves `autoenablesItems` at its default `true`, so AppKit
    /// asks the target (this delegate) before showing each item. Everything
    /// else routed here is unconditional, and an item whose selector isn't
    /// handled below must stay enabled, so the default is `true`.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        // Nil when the updater never started (`--smoke`, or no Metal device),
        // where the item would do nothing at all.
        return updateController?.canPerformCheck ?? false
    }

    /// App menu > Check for Updates…: forward to the Sparkle updater.
    /// No-op if the updater didn't start (e.g. `--smoke`).
    @objc
    func checkForUpdates(_ sender: Any?) {
        updateController?.checkForUpdates(sender)
    }

    /// Debug (DEVICETERM_UPDATE_SIMULATOR=1): cycle the update pill
    /// through every state without a live feed.
    @objc
    func simulateUpdatePill(_ sender: Any?) {
        updateController?.simulateStates()
    }

    /// App menu > About DeviceTerm: show (or re-front) the custom About
    /// window (replaces `orderFrontStandardAboutPanel`).
    @objc
    func openAbout(_ sender: Any?) {
        if aboutWC == nil {
            aboutWC = AboutWindowController()
        }
        aboutWC?.showWindow(nil)
        aboutWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open the config in a new terminal tab running `$EDITOR`. Reuses
    /// the key window; with no window open, opens one whose initial tab
    /// runs the editor (Router-direct because `RouteIntent.openWindow`
    /// doesn't model an initial command; same rationale as the
    /// boot-time orphan reattach).
    private func openConfigEditorTab(configPath: String) {
        let configDir = (configPath as NSString).deletingLastPathComponent
        let tokens = SettingsEditorCommand.tokens(forConfigPath: configPath)
        if workspace.selectedWindowID != nil {
            dispatchIntent(
                .openTab(inWindow: nil, role: .agent, cwd: configDir, cmd: tokens)
            )
        } else {
            router.dispatch(.openWindow(cwd: configDir, command: tokens))
        }
    }

    // MARK: - Reconcile (observe { reconcileWindows() })

    /// Reflect workspace.windows into the WindowController set. Reads the
    /// windows array each pass (observe() tracking contract).
    private func reconcileWindows() {
        let liveIDs = Set(workspace.windows.map(\.id))

        // Drop WCs for windows the Router removed. windowWillClose may
        // already have dropped the WC; this catches the close-from-Router
        // path (e.g. quit) and clears closing-in-flight bookkeeping. Run
        // per-tab teardown before closing the window so libghostty
        // surfaces / discovery observers / PaneResurrect watches don't leak.
        for windowID in Array(windowControllerByID.keys) where !liveIDs.contains(windowID) {
            if let windowCtl = windowControllerByID.removeValue(forKey: windowID) {
                (windowCtl.contentViewController as? TabStripViewController)?.teardown()
                windowCtl.window?.close()
            }
            closingWindowIDs.remove(windowID)
        }
        // Also clear closingWindowIDs entries whose WindowState is gone.
        closingWindowIDs.formIntersection(liveIDs)

        // Create WCs for new WindowStates. Skip windows still tearing
        // down (their WC was dropped synchronously in windowWillClose).
        for windowState in workspace.windows
        where windowControllerByID[windowState.id] == nil
            && !closingWindowIDs.contains(windowState.id) {
            let tabController = TabStripViewController(
                windowID: windowState.id,
                tabListVM: windowState.tabs,
                daemonClient: daemonClient,
                paneResurrect: paneResurrect,
                router: router,
                intentDispatcher: intentDispatcher
            )
            tabController.tabTransfer = self
            let windowCtl = WindowController(content: tabController)
            windowCtl.window?.delegate = self
            windowControllerByID[windowState.id] = windowCtl
            windowCtl.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "DeviceTerm"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Surface the should-never-happen restore-contract violation: a live
    /// terminal with a sessionId but no immutable short id, which the daemon
    /// always supplies at `session.create`. The bad terminal can't be restored,
    /// but the condition clears if the user closes/reopens it, so the durable
    /// loop keeps polling; this just notes the condition once: always to stderr,
    /// and (once per launch) as a non-fatal informational alert, since a bare
    /// stderr write is invisible in a GUI app. Not `fail(...)`; this doesn't
    /// warrant quitting; the affected tab can be reopened.
    private func reportRestoreContractViolation() {
        // Guard FIRST so the durable poll doesn't repeat the log (or the alert)
        // on every iteration; both fire exactly once per launch.
        guard !restoreContractViolationReported else { return }
        restoreContractViolationReported = true
        let note = "deviceterm: session restore blocked; a live terminal is "
            + "missing its short id (daemon-contract violation)\n"
        FileHandle.standardError.write(Data(note.utf8))
        let alert = NSAlert()
        alert.messageText = "DeviceTerm"
        alert.informativeText = "Session restore was interrupted: a terminal is "
            + "missing internal identity and couldn't be restored after the "
            + "helper restarted. Affected tabs may need to be reopened."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - IntentActionDelegate

/// AppDelegate carries the live `windowControllerByID` map, so it's
/// the natural place to resolve a (window, tab) pair to the
/// `TabStripViewController` that owns the tab's view stack. Intents
/// that don't fit the Route shape (`renameTab`, plus any future
/// linkage-mutation) hop through here.
extension AppDelegate: IntentActionDelegate {
    func renameTab(window windowID: WindowID, tab tabID: TabID, to name: String?) {
        // Find the owning strip via the existing window map, then
        // hand off to the strip's programmatic rename hook (which
        // applies the rename without the modal sheet that the menu
        // path uses). Silent no-op when the window/tab is gone;
        // that's the natural concurrent outcome (caller dispatched,
        // user closed the tab before the route landed).
        guard let windowCtl = windowControllerByID[windowID],
            let strip = windowCtl.contentViewController as? TabStripViewController
        else { return }
        strip.renameTab(id: tabID, to: name)
    }

    func sendInput(
        window windowID: WindowID,
        tab tabID: TabID,
        text: String,
        typeDelayMillis: Int?
    ) throws {
        // Same window → strip → tab-content lookup as renameTab,
        // but throws when the window or tab isn't reachable so the
        // dispatcher relays the typed error back to the
        // originating CLI handler (automation's
        // `deviceterm tab send-input` should see "tab gone" rather
        // than a misleading ok).
        guard let windowCtl = windowControllerByID[windowID],
            let strip = windowCtl.contentViewController as? TabStripViewController
        else {
            throw IntentError.notFound(
                kind: "window",
                ref: "\(windowID.value)"
            )
        }
        try strip.sendInput(
            toTab: tabID,
            text: text,
            typeDelayMillis: typeDelayMillis
        )
    }

    func captureTab(window windowID: WindowID, tab tabID: TabID) throws -> String {
        // Same lookup shape as sendInput; surfaces the captured
        // viewport text or a typed error to the dispatcher.
        guard let windowCtl = windowControllerByID[windowID],
            let strip = windowCtl.contentViewController as? TabStripViewController
        else {
            throw IntentError.notFound(
                kind: "window",
                ref: "\(windowID.value)"
            )
        }
        return try strip.captureTab(id: tabID)
    }

    func raiseWindow(_ windowID: WindowID) {
        // No live controller for the id: the window is closing, or it
        // was just added and reconcile hasn't built one yet. Silent
        // no-op either way.
        guard let window = windowControllerByID[windowID]?.window else { return }
        window.makeKeyAndOrderFront(nil)
        // `makeKeyAndOrderFront` only orders within the app, and a
        // window in a background app can't take key at all, so without
        // the activation the raise would stay invisible until the user
        // clicked back into DeviceTerm. Same pair `reconcileWindows`
        // runs on a window it just created.
        NSApp.activate(ignoringOtherApps: true)
    }

    func moveTabAcrossWindows(_ tab: TabID, from: WindowID, to destination: WindowID, atIndex: Int) {
        // CLI `deviceterm tab move --to-window`: forward to the transfer
        // coordinator (same relocation the cross-window drag uses).
        moveTab(tab, from: from, to: destination, atIndex: atIndex)
    }
}

// MARK: - TabTransferCoordinating

/// Cross-window tab drag lands here: AppDelegate owns the window-controller
/// registry, so it's the one place that can reach both the source and
/// destination strips to relocate a live `TabContentViewController`. The
/// relocation runs as a single synchronous block (no `await`) so neither
/// strip's async `render()` interleaves and tears the moved shell down;
/// see `TabStripViewController.extractTabContent`.
extension AppDelegate: TabTransferCoordinating {
    func moveTab(_ tab: TabID, from: WindowID, to destination: WindowID, atIndex: Int) {
        // Reject a transfer touching a window whose close is in progress: its
        // membership is frozen at the set `window.close` was authorized
        // against. Moving a (possibly foreign) tab into a closing window would
        // see it destroyed without authority; moving one out would race the
        // teardown.
        guard !router.isWindowClosing(from), !router.isWindowClosing(destination) else { return }
        guard from != destination,
            let sourceStrip = strip(for: from),
            let destStrip = strip(for: destination),
            let sourceVM = workspace.window(id: from)?.tabs,
            let destVM = workspace.window(id: destination)?.tabs,
            let tabContent = sourceStrip.extractTabContent(id: tab)
        else { return }
        guard let state = sourceVM.detach(id: tab) else {
            // Detach failed after the extract (tab vanished); put the
            // live VC back so it isn't stranded.
            sourceStrip.adoptTabContent(tabContent, for: tab)
            return
        }
        destStrip.adoptTabContent(tabContent, for: tab)
        destVM.insert(state, at: atIndex, select: true)
        // Track the destination as the selected window so `--current`
        // window resolution (e.g. `deviceterm tab open` from the moved
        // tab) and `windows list`'s key-window flag follow the move,
        // not just AppKit focus.
        workspace.select(id: destination)
        destStrip.view.window?.makeKeyAndOrderFront(nil)
    }

    func tearOffTab(_ tab: TabID, from: WindowID, at screenPoint: NSPoint) {
        // A closing window's membership is frozen; don't tear a tab out of it.
        guard !router.isWindowClosing(from) else { return }
        guard let sourceStrip = strip(for: from),
            let sourceVM = workspace.window(id: from)?.tabs
        else { return }
        // Tearing off the sole tab would just close-and-recreate the same
        // window; skip it (the drag reads as a no-op).
        guard sourceVM.tabs.count > 1,
            let tabContent = sourceStrip.extractTabContent(id: tab)
        else { return }
        guard let state = sourceVM.detach(id: tab) else {
            sourceStrip.adoptTabContent(tabContent, for: tab)
            return
        }
        // Build the new window's nav state + strip holding the live VC,
        // register the WC BEFORE adding the WindowState so the async
        // reconcile skips rebuilding it, then front it.
        let newID = router.mintWindowID()
        let destVM = TabListViewModel()
        destVM.insert(state, at: 0, select: true)
        let strip = TabStripViewController(
            windowID: newID,
            tabListVM: destVM,
            daemonClient: daemonClient,
            paneResurrect: paneResurrect,
            router: router,
            intentDispatcher: intentDispatcher,
            adopting: [(tab, tabContent)]
        )
        strip.tabTransfer = self
        let windowCtl = WindowController(content: strip)
        windowCtl.window?.delegate = self
        windowCtl.position(topLeftNear: screenPoint)
        windowControllerByID[newID] = windowCtl
        workspace.addWindow(WindowState(id: newID, tabs: destVM))
        windowCtl.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func strip(for windowID: WindowID) -> TabStripViewController? {
        windowControllerByID[windowID]?.contentViewController as? TabStripViewController
    }
}

private extension AppDelegate {
    /// Thrown when the startup recovery ladder could not get a matching helper
    /// answering, carrying what to tell the user.
    ///
    /// An error rather than a return value so it unwinds the launch sequence the
    /// same way a connect failure does, leaving one place that decides what a
    /// failed launch shows.
    struct StartupVersionSurrender: Error {
        let situation: UpdateRestartSituation
    }
}

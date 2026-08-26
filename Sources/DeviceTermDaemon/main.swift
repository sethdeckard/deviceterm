// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Daemon
import Darwin
import Foundation

// deviceterm-daemon: executable wrapper around the `Daemon` library.
//
// Lifecycle:
//   1. Switch NSApp to .accessory so the daemon doesn't show a Dock
//      icon and can host an NSStatusItem.
//   2. Resolve the UDS path (env override or default in
//      ~/Library/Application Support/deviceterm/daemon.sock).
//   3. Construct the actors that own daemon state: SessionManager,
//      DeviceCoordinator, PaneCoordinator, PhysicalDeviceCoordinator,
//      AutomationGrantStore, and TerminalAnchorStore.
//   4. Start both transports on one shared method registry: the
//      RPCServer on the UDS path and the XPCServer on the mach service.
//   5. Start the StatusItemController and IdleMonitor.
//   6. Run the NSApp event loop. NSApp.terminate(nil) unwinds it, from
//      any of: a bootstrap failure, the `daemon.shutdown` RPC, the idle
//      timeout, SIGTERM, or the menu's "Quit" item.

/// When a daemon instance started, and why it exited.
///
/// stderr goes nowhere once launchd owns the process, so unified logging is the
/// only durable record. Known exit routes log a reason, and
/// `applicationWillTerminate` marks every clean teardown. No termination line
/// means the hook did not run, as with a crash, a SIGKILL, or another unhandled
/// fatal signal.
private let lifecycleLog = DiagnosticLog.lifecycle

@MainActor
final class DeviceTermDaemonDelegate: NSObject, NSApplicationDelegate {
    private var server: RPCServer?
    private var xpcServer: XPCServer?
    private var subscriptionRegistry: PaneSubscriptionRegistry?
    private var statusItem: StatusItemController?
    private var idleMonitor: IdleMonitor?
    private var sessionManager: SessionManager?
    private var deviceCoordinator: DeviceCoordinator?
    private var paneCoordinator: PaneCoordinator?
    private var eventBroker: EventBroker?
    private var tunnelKeepalive: TunnelKeepalive?
    private var socketPath: String?

    /// MIGRATION: Best-effort scrub of the legacy on-disk state manifest.
    ///
    /// The daemon holds session/device/pane state in memory only: a fresh
    /// instance starts empty and the GUI restores session state, and a
    /// same-uid-writable file is untrusted input, so nothing authority-bearing
    /// is loaded from disk. Daemon startup removes any legacy
    /// `daemon-state.v1.json` from an earlier build that may still hold
    /// `capabilityVerifier` material, on a best-effort basis: unlink it so it
    /// isn't left readable. The security property is that no code path *reads*
    /// it. The unlink is hygiene, not a dependency, so its failure is ignored.
    private static func scrubLegacyStateManifest() {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let manifest = base
            .appendingPathComponent("deviceterm", isDirectory: true)
            .appendingPathComponent("daemon-state.v1.json", isDirectory: false)
        try? FileManager.default.removeItem(at: manifest)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await bootstrap()
            } catch {
                // Log the error type publicly and its payload privately.
                // Socket-bind and Application Support failures embed a
                // filesystem path, which carries the account name or whatever
                // `DEVICETERM_DAEMON_SOCK` was set to. The type alone says
                // which stage failed.
                lifecycleLog.error(
                    """
                    exit: bootstrap failed: \
                    \(String(describing: type(of: error)), privacy: .public) \
                    \(error, privacy: .private)
                    """
                )
                FileHandle.standardError.write(
                    Data("deviceterm-daemon: bootstrap failed: \(error)\n".utf8)
                )
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Fires on every clean termination, including routes that never reach
        // one of the named exit paths, such as a system logout. Absence of this
        // line means the termination hook did not run, as with a crash, a
        // SIGKILL, or another unhandled fatal signal.
        lifecycleLog.notice("exit: clean teardown")
        // Unlink the socket *synchronously* before the runloop tears
        // down. A detached Task would race against process exit. This
        // is the clean path; `bindListener` also self-heals a stale
        // socket left by an *unclean* exit (SIGKILL/crash, which never
        // reaches this hook), so a leftover `daemon.sock` doesn't wedge
        // the next spawn. The listener fd is closed by the
        // kernel on death, so we only clear the filesystem entry here.
        if let path = socketPath {
            path.withCString { _ = Darwin.unlink($0) }
        }
        // SIGINT every borrowed `devicectl` tunnel keepalive synchronously
        // before the runloop tears down, so a clean exit never orphans one.
        // (A crash skips this hook; the next launch's `reapOrphans()` and the
        // keepalive's own session-timeout are the backstops.)
        tunnelKeepalive?.shutdownAll()
        statusItem?.stop()
    }

    private func bootstrap() async throws {
        let socketPath = try resolveSocketPath()

        // One EventBroker per daemon, threaded through every
        // publisher (the three coordinators) and the registry's
        // daemon.events handler. A fresh broker per construction
        // would leave publishers and subscribers connected to
        // different instances: the daemon.events stream would
        // attach but never receive events.
        let eventBroker = EventBroker()

        // The daemon holds NO session/device/pane state from disk. A fresh
        // instance starts empty; a validated GUI re-supplies its live session
        // inventory over XPC via `session.restoreBatch` (owned sims are
        // GUI-reclaimed, never rehydrated from a file). Scrub any legacy
        // manifest so old credential material can't linger at rest.
        Self.scrubLegacyStateManifest()
        // Per-frame surface leasing is on unless the kill switch is set to
        // "0", then device frames deliver like simulator frames (no holds,
        // no acks), while the token/drain subscription lifecycle stays on.
        let leasingEnabled = ProcessInfo.processInfo
            .environment[DeviceTermEnv.surfaceLeases] != "0"
        let subscriptionRegistry = PaneSubscriptionRegistry(leasingEnabled: leasingEnabled)
        // One live automation-grant store, handed to the session manager.
        // `DaemonMethods.defaultRegistry` sources the registry's store (which
        // the grant/revoke handlers write, both dispatchers' scope checks read,
        // and `daemon.capabilities` advertises from) FROM the manager, so the
        // ledger enforcement reads, the ledger the handlers mutate, and the
        // ledger close-revocation touches are the same instance by construction,
        // not merely equal by convention. Never persisted; empty at start.
        let automationGrantStore = AutomationGrantStore()
        // One live terminal-anchor store shared by the session manager
        // (register/revoke on create/close), the `session.bindTerminal`
        // handler (the validated GUI binds a session's terminal), the UDS
        // connections' provenance gate (matches an in-tab caller against the
        // bound anchor), and the XPC close path (revokes a GUI connection's
        // anchors). Never persisted; empty at start.
        let terminalAnchorStore = TerminalAnchorStore()
        // Start pending restoration: a fresh daemon holds no session, so an
        // unknown-session `session.authenticate` is retryable (`notReady`)
        // rather than a hard `unauthorized` until a validated GUI supplies its
        // inventory via `session.restoreBatch` (even an empty batch releases
        // the barrier).
        let sessionManager = SessionManager(
            eventBroker: eventBroker,
            startsPendingRestoration: true,
            automationGrantStore: automationGrantStore,
            terminalAnchorStore: terminalAnchorStore
        )
        // One provenance context derived from the session manager: the store
        // the bindTerminal handler, the per-request lookup, and the XPC close
        // path use is guaranteed the same instance. Passed to BOTH the registry
        // (which preconditions the manager matches) and the servers.
        let provenance = ProvenanceContext(sessionManager: sessionManager)
        let deviceCoordinator = DeviceCoordinator(
            eventBroker: eventBroker
        )
        let paneCoordinator = PaneCoordinator(
            eventBroker: eventBroker,
            subscriptionRegistry: subscriptionRegistry
        )
        // Wire the pane-subscription revoker so a session close tears down its
        // panes' subscriptions before the close returns. Installed here, before
        // the RPC servers bind; the precondition just before `bind` fails closed
        // if that ordering ever regresses, so revocation is never silently
        // skipped.
        await sessionManager.setPaneRevoker { sessionId in
            await paneCoordinator.revokeSubscriptions(forSession: sessionId)
        }
        // Cohort teardown runs for EVERY teardown reason, not only an explicit
        // `session.close`: a restore-batch reap removes sessions through the
        // same path, and a reaped member of a live tab must hand its panes and
        // devices to the survivors before the subscription sweep can orphan
        // them. This also installs the effect pump, the ordered channel that
        // carries cohort device consequences into `DeviceCoordinator`.
        await SessionCohortMethods.installCohortWiring(
            sessionManager: sessionManager,
            paneCoordinator: paneCoordinator,
            deviceCoordinator: deviceCoordinator
        )
        // The paired activation seam: a session reaching ready pushes its active
        // incarnation to the pane coordinator, whose synchronous ownership-commit
        // check reads it to refuse a stale-incarnation create/re-attach/adopt.
        await sessionManager.setPaneActivator { sessionId, incarnation in
            await paneCoordinator.noteSessionActive(sessionId, incarnation: incarnation)
        }
        // Reap any tunnel keepalives orphaned by a previously-crashed daemon
        // (identified by their unique notification name) before standing up
        // our own, so we don't leave stale `devicectl` processes holding
        // tunnels up across an unclean restart.
        await TunnelKeepalive.reapOrphans()
        let tunnelKeepalive = TunnelKeepalive()
        // Store the keepalive before the next suspension so
        // `applicationWillTerminate` can shut it down. `shutdownAll()` is
        // harmless before any tunnel is retained.
        self.tunnelKeepalive = tunnelKeepalive
        let physicalDeviceCoordinator = PhysicalDeviceCoordinator(keepalive: tunnelKeepalive)

        // Set-level CoreSimulator notification subscription. Fills
        // the shim's argv-detection blind spots: xcodebuild,
        // Simulator.app, absolute-path `/usr/bin/xcrun simctl boot`,
        // FFI callers, sims booted before the daemon started, so
        // `deviceterm events` and `device.list` see every transition.
        // Degraded-mode tolerant: a failure here (CoreSimulator
        // unloadable, registration refused) is logged but doesn't
        // abort daemon startup; the shim path stays useful.
        do {
            // The converger is a parameter, not a later `set…` call, so the
            // notifier cannot be installed without the half that drives
            // attached panes into `.shutdown`.
            try await deviceCoordinator.subscribeToCoreSimulator(
                paneShutdownConverger: { udid in
                    await paneCoordinator.markPanesShutdown(forUDID: udid)
                }
            )
        } catch {
            let line = "deviceterm-daemon: CoreSimulator notification subscription failed: \(error);"
                + " falling back to shim-only attribution\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let registry = DaemonMethods.defaultRegistry(
            sessionManager: sessionManager,
            deviceCoordinator: deviceCoordinator,
            paneCoordinator: paneCoordinator,
            physicalDeviceCoordinator: physicalDeviceCoordinator,
            eventBroker: eventBroker,
            provenance: provenance,
            shutdownTrigger: {
                // `daemon.shutdown` is validated-GUI-only and used for
                // wire-version remediation, so this notice identifies that
                // exit path specifically.
                lifecycleLog.notice("exit: daemon.shutdown RPC; terminating")
                let line = "deviceterm-daemon: explicit shutdown RPC; terminating\n"
                FileHandle.standardError.write(Data(line.utf8))
                // Bounce back to the main thread so NSApp's
                // termination machinery (and our own
                // `applicationWillTerminate` hook, which unlinks the
                // socket) runs cleanly.
                await MainActor.run {
                    NSApp.terminate(nil)
                }
            }
        )
        let authValidator: AuthValidator = { sessionId, capability in
            try await sessionManager.validate(
                sessionId: sessionId,
                capability: capability
            )
        }
        // Fail closed: a closed session's subscriptions must be revocable
        // before any connection can open one. This asserts the composition
        // above ran; a regression that dropped the wiring stops the daemon
        // here rather than silently leaking a closed session's stream.
        let revokerInstalled = await sessionManager.hasPaneRevoker
        precondition(
            revokerInstalled,
            "pane-subscription revoker must be installed before the RPC servers accept connections"
        )
        // Same fail-closed rule for the cohort seam: a teardown that skipped
        // it would leave the dead session in every sibling's membership.
        let cohortRevokerInstalled = await sessionManager.hasCohortRevoker
        precondition(
            cohortRevokerInstalled,
            "cohort revoker must be installed before the RPC servers accept connections"
        )
        // And for the effect pump: without a sink, a cohort close would
        // silently drop the tombstone and transfer its verdict owes the
        // device layer.
        let effectSinkInstalled = await paneCoordinator.hasDeviceEffectSink
        precondition(
            effectSinkInstalled,
            "cohort effect sink must be installed before the RPC servers accept connections"
        )
        let server = RPCServer(
            socketPath: socketPath,
            methods: registry,
            authValidator: authValidator
        )
        try await server.start()
        // Store the socket path only after `start()` succeeds, since a
        // bootstrap that failed to bind because another daemon holds that path
        // would otherwise unlink the live daemon's socket. Store it before the
        // next suspension so SIGTERM cleanup can find it.
        self.socketPath = socketPath
        FileHandle.standardOutput.write(
            Data("deviceterm-daemon: listening on \(socketPath)\n".utf8)
        )
        // XPC server vends the launchd-vended mach service that
        // the GUI connects to. The CLI keeps UDS; both transports
        // share the same `MethodRegistry`, so a method registered
        // once is callable over either.
        let xpcServer = XPCServer(
            methods: registry,
            authValidator: authValidator,
            subscriptionRegistry: subscriptionRegistry
        )
        await xpcServer.bindMachService(name: MachServiceName.daemon)
        FileHandle.standardOutput.write(
            Data("deviceterm-daemon: vending mach service \(MachServiceName.daemon)\n".utf8)
        )
        // Both transports are up. The pid is what makes restarts legible in a
        // `log show` timeline: a *new* pid here means the process died and was
        // relaunched, as opposed to one connection dropping while the daemon
        // lived (which the `xpc` category records instead).
        lifecycleLog.notice(
            """
            startup: serving pid \
            \(ProcessInfo.processInfo.processIdentifier, privacy: .public)
            """
        )

        let statusItem = StatusItemController(
            coordinator: deviceCoordinator,
            paneCoordinator: paneCoordinator,
            sessionManager: sessionManager
        )
        await statusItem.refresh()
        statusItem.start()

        // Stay-alive predicate per docs/ARCHITECTURE.md: any connected RPC
        // peer (GUI XPC / CLI UDS) OR a pane retirement cleanup still in
        // flight OR a non-terminal pane whose owner GUI is still alive OR any
        // deviceterm-owned booted sim. The pane clause uses
        // owner liveness (not raw pane count) so an abandoned pane doesn't pin
        // the daemon; the sim clause uses `ownedBootedCount` (ownership map ∩
        // live CoreSimulator Booted state), not `ownedCount`. An external
        // shutdown normally removes the ownership record
        // (`DeviceCoordinator.noteExternalShutdown`); intersecting with live
        // Booted state means that even if that notification is missed, a stale
        // record can't keep the daemon alive with no real sim behind it.
        let idleMonitor = IdleMonitor(
            isBusy: {
                let udsConnections = await server.activeConnectionCount
                if udsConnections > 0 { return true }
                let xpcConnections = await xpcServer.connectionCount
                if xpcConnections > 0 { return true }
                // A non-terminal pane whose owner GUI is still alive keeps the
                // daemon up: a physical-device pane (no CoreSimulator boot
                // state) or a sim pane across a momentary GUI-connection lapse.
                // A daemon exit destroys live pane and backend state (a fresh
                // daemon restores nothing from disk; a mirror is rebuilt only
                // through the normal attach path), so hold on while a mirror is
                // genuinely in use. A pane abandoned by a crashed GUI does
                // NOT count (its owner fails the liveness check), so the daemon
                // can still idle-exit and reap its tunnels; the idle grace
                // window already covers a brief reconnect.
                // A pane whose retirement cleanup is still running has already
                // left `liveOwnerSessionIds`, and a physical-device pane has no
                // owned-booted-sim fallback to hold the daemon up. Exiting
                // there abandons a backend, a tunnel, and any final lift.
                if await paneCoordinator.hasDeferredCleanup {
                    return true
                }
                let liveOwners = await paneCoordinator.liveOwnerSessionIds
                for owner in liveOwners where await sessionManager.isAlive(owner) {
                    return true
                }
                let owned = await deviceCoordinator.ownedBootedCount()
                return owned > 0
            },
            terminate: {
                // Report the predicate rather than re-reading it. A second
                // sample would still be non-atomic and could be stale by the
                // time it is logged, while each added await extends the
                // decision-to-exit window. A peer connecting inside that window
                // is stranded: a UDS client cannot demand-launch a replacement,
                // and an XPC client recovers only by observing an invalidated
                // connection.
                lifecycleLog.notice(
                    """
                    exit: idle timeout, last busy sample found no connected \
                    peers, no pane with a live owner, and no owned booted sims
                    """
                )
                let line = "deviceterm-daemon: idle timeout reached; no connected"
                    + " peers, no live-owned panes, no confirmed owned booted"
                    + " sims; terminating\n"
                FileHandle.standardError.write(Data(line.utf8))
                await MainActor.run {
                    NSApp.terminate(nil)
                }
            }
        )
        await idleMonitor.start()

        // Retain references so ARC keeps the actors alive for the
        // process's lifetime.
        self.sessionManager = sessionManager
        self.deviceCoordinator = deviceCoordinator
        self.paneCoordinator = paneCoordinator
        self.eventBroker = eventBroker
        self.server = server
        self.xpcServer = xpcServer
        self.subscriptionRegistry = subscriptionRegistry
        self.statusItem = statusItem
        self.idleMonitor = idleMonitor
    }
}

/// Resolve the daemon's UDS path. Order:
///   1. `DEVICETERM_DAEMON_SOCK` env var (dev / test overrides).
///   2. `~/Library/Application Support/deviceterm/daemon.sock`,
///      created if the parent directory is missing.
func resolveSocketPath() throws -> String {
    if let override = ProcessInfo.processInfo.environment[DeviceTermEnv.daemonSock],
        !override.isEmpty {
        return override
    }
    let supportDir = try FileManager.default
        .url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("deviceterm", isDirectory: true)
    try FileManager.default.createDirectory(
        at: supportDir,
        withIntermediateDirectories: true
    )
    return supportDir.appendingPathComponent("daemon.sock").path
}

/// Turn SIGTERM into a clean, logged termination.
///
/// SIGTERM's default action skips `applicationWillTerminate`, leaving the
/// socket on disk and borrowed tunnel keepalives orphaned, and writes no log
/// line. Ignoring the default action and handling the signal on the main queue
/// routes it through `NSApp.terminate`, which runs the ordinary teardown.
///
/// Returned rather than discarded because a `DispatchSourceSignal` stops
/// delivering once it deallocates.
func installTerminationSignalHandler() -> DispatchSourceSignal {
    // Suppress the default action before creating the source, so a SIGTERM
    // arriving between `makeSignalSource` and `resume` cannot kill the process
    // outright.
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
        // The source runs on `.main`, so use `MainActor.assumeIsolated`:
        // `setEventHandler` takes a nonisolated closure and cannot carry that
        // fact, while `NSApp.terminate` is main-actor-isolated. Hopping through
        // a Task instead would let the process outlive the signal by a turn.
        MainActor.assumeIsolated {
            lifecycleLog.notice("exit: SIGTERM received; terminating")
            FileHandle.standardError.write(
                Data("deviceterm-daemon: SIGTERM received; terminating\n".utf8)
            )
            NSApp.terminate(nil)
        }
    }
    source.resume()
    return source
}

// A daemon must never die because one peer hung up. Sockets set
// `SO_NOSIGPIPE` individually, which is the precise fix and stays the
// requirement for new code; this is the process-wide backstop, because the cost
// of missing it on one descriptor is not a failed write but the loss of every
// pane the daemon owns. Ignoring the signal makes the offending write return
// `EPIPE`, which the socket layers already surface as ordinary errors.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = DeviceTermDaemonDelegate()
app.delegate = delegate
// Retain the source for the process lifetime. A top-level `let` is a global
// with static storage, so it keeps delivering. If it deallocated, the earlier
// `SIG_IGN` disposition would remain installed, leaving SIGTERM ignored with no
// handler to receive it.
let terminationSignalSource = installTerminationSignalHandler()
app.run()

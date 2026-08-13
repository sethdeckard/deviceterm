// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonClient: the GUI's single persistent RPC connection.
//
// `@MainActor` (not an actor): the surface, its delegate, the VCs and
// NSWindow are all main-actor; an actor would force a hop per request
// and invite subscription-replay reentrancy. The XPC transport
// underneath (`XPCDaemonConnection`) is an actor and serializes its
// own state; this façade just adapts the RPC envelope shape to the
// role-protocol surface the rest of the GUI consumes.
//
// **Transport.** The GUI talks to the daemon over a launchd-vended
// XPC mach service. The daemon registers via `SMAppService.agent`
// (`DaemonRegistration` on the App side); the mach service name
// lives in `MachServiceName.daemon` (DaemonProtocol). There is no
// `Process()` spawn fallback. Developer-ID signing is the
// production path, and ad-hoc / unsigned builds also flow through
// XPC (so contributors hit the same code path as production users).
//
// **Subscriptions.** `subscribePane` returns a stream that pairs
// each `surface.changed` JSON evt with its matching side-band
// surface payload: the `XPCDaemonConnection` does the
// `(paneId, sequence)` correlation and `IOSurfaceLookupFromXPCObject`
// invisibly. Callers see typed `PaneEvent` values, not raw frames.

import DaemonProtocol
import Foundation
@preconcurrency import IOSurface
import os
#if canImport(Darwin)
import Darwin
#endif

/// Logs daemon-client reconnect cycles, including superseded handshakes.
/// Reconnect-handshake generations advance after transport generations; do not
/// correlate the two.
private let reconnectLog = Logger(subsystem: "com.deviceterm", category: "reconnect")

/// Logs session-lifecycle outcomes the GUI has no other way to surface,
/// notably a session it created but could neither hand to a tab nor close.
private let sessionLog = Logger(subsystem: "com.deviceterm", category: "session")

/// Decoded events from a `pane.subscribe` stream.
///
/// The XPC transport delivers two messages per surface update: the JSON
/// `surface.changed` evt (carrying `paneId` + `sequence`) and a side-band
/// surface payload carrying the subscription token, the `leased`/`leaseEpoch`
/// overlay, and an XPC object that resolves to an `IOSurfaceRef`. The
/// `XPCDaemonConnection` correlates the pair by `(paneId, sequence, token)`
/// and synthesizes a single `surfaceChanged(_, SurfaceLease?)` event for the
/// VM. The lease is nil when the side-band payload was missing (timeout /
/// reorder); the view holds the previous surface in that case.
enum PaneEvent: Sendable {
    /// The lease is nil on a JSON-only frame (timeout / reorder, the view
    /// keeps its previous surface) and always nil over UDS. A leased device
    /// frame carries a leased `SurfaceLease` (use-count bumped, released on ARC
    /// deinit → the daemon frees the slot); an unleased frame (every
    /// simulator frame, and every device frame when `DEVICETERM_SURFACE_LEASES`
    /// is off) carries a `SurfaceLease` with no use-count and no ack.
    case surfaceChanged(SurfaceChangedEvent, SurfaceLease?)
    case stateChanged(StateChangedEvent)
    case orientationChanged(OrientationChangedEvent)
}

enum DaemonClientError: Error, CustomStringConvertible {
    case transport(String)
    case daemon(
        code:
        Int,
        message: String
        )
    case versionMismatch(
        client:
        String,
        daemon: String
        )
    case decode(String)
    /// `daemon.shutdown` returned without a `{ok: true}` ack: the
    /// incompatible daemon did not confirm it is terminating.
    case shutdownNotAcknowledged
    /// `daemon.shutdown` was sent but no reply arrived within the bound: a
    /// daemon that answers `ping` but never acks shutdown must not stall
    /// startup/reconnect. The daemon's state is unknown (indeterminate).
    case shutdownTimedOut
    /// The call went out and no answer came back within its bound.
    ///
    /// The wait was abandoned, not the work: nothing cancels the daemon's
    /// handler, so the call may still complete on its side. What happens to
    /// that late reply depends on which bound raised this.
    ///
    /// For an ordinary request the transport was cancelled and the reply is
    /// discarded. A mutation bounded that way still has an unknown outcome,
    /// but none of those calls return a one-time identity, so nothing is lost
    /// that the GUI would need to name what it may have changed.
    ///
    /// The calls that *do* return one are bounded by their own caller through
    /// `Deadline.wait`, which lets the call finish and reconciles what it
    /// produced: `createSession` attempts to close a session no tab ever
    /// received, and `Router.runAttach` attempts to detach a pane no window is
    /// showing. Both are best-effort. Without that,
    /// a `session.create` reply would strand a session nobody can name (its
    /// capability leaves the daemon exactly once, and it survives an omitting
    /// `session.restoreBatch` on the same connection, since a live create's
    /// assertion deliberately outranks a restore baseline at that epoch), and
    /// an attach reply would strand a pane holding its device, and for a
    /// physical device its tunnel.
    case timedOut(method: String)

    var description: String {
        switch self {
        case let .transport(detail):
            return "transport error: \(detail)"

        case let .daemon(code, message):
            return "daemon error \(code): \(message)"

        case let .versionMismatch(client, daemon):
            return "daemon wire version \(daemon) != client \(client)"

        case let .decode(detail):
            return "decode error: \(detail)"

        case .shutdownNotAcknowledged:
            return "daemon.shutdown was not acknowledged"

        case .shutdownTimedOut:
            return "daemon.shutdown timed out awaiting acknowledgement"

        case let .timedOut(method):
            return "timed out: the deviceterm helper did not answer \(method)"
        }
    }

    var isVersionMismatch: Bool {
        if case .versionMismatch = self { return true }
        return false
    }
}

/// The result of handling a definite daemon wire-version mismatch: the GUI tries
/// to stop the incompatible daemon (so the next launch doesn't reconnect to it)
/// before surfacing the user-facing remediation.
struct VersionMismatchOutcome: Sendable {
    /// The shutdown-request outcome. Deliberately NOT a "stopped" boolean: an
    /// acknowledgement proves the daemon *accepted* the request (termination is
    /// imminent, not necessarily already complete), and a lost ack is genuinely
    /// *unknown*: a transport drop can race an accepted shutdown. So the two
    /// honest states are "confirmed acceptance" and "indeterminate".
    enum Shutdown: Sendable {
        /// The daemon acknowledged the request: it accepted the shutdown.
        case confirmed
        /// No acknowledgement arrived (a transport loss that may or may not have
        /// raced an accepted shutdown, an explicit `{ok:false}`, or a transport
        /// that structurally can't request one). The daemon's state is unknown.
        case indeterminate(String)
    }

    let mismatch: DaemonClientError
    let shutdown: Shutdown
}

/// The `daemon.shutdown` reply: the shared `{ok: true}` ack shape.
private struct DaemonShutdownAck: Decodable {
    let ok: Bool
}

/// Internal transport abstraction so `DaemonClient` can route over
/// XPC (production) or UDS (smoke-mode-only fallback) without
/// changing its public surface.
private enum DaemonTransport {
    case xpc(XPCDaemonConnection)
    case uds(UDSDaemonConnection)
}

@MainActor
final class DaemonClient: SessionControlling, DeviceControlling, OrchestratorGranting,
    PhysicalDeviceControlling, PaneControlling, PaneSubscribing,
    PaneAccessibilityControlling, PaneLocationControlling,
    AppCommandControlling, TerminalBinding,
    ReconnectObserving, DisplayTitlePublishing {
    /// `true` when the GUI was launched with `--smoke` *and* a UDS
    /// override path is in the environment. The smoke harness sets
    /// both; production never does.
    ///
    /// The UDS fallback is a degraded transport: it carries no audit
    /// token, so the daemon refuses the `.validatedGUI` back-channel
    /// (`app.commands` / `app.commandResult`). Multi-tab pane control
    /// runs over that back-channel, so it is **XPC-only**: smoke runs
    /// deliberately lose it (see `AppCommandSubscriber`'s terminal
    /// back-channel-refused handling).
    private static var isSmokeMode: Bool {
        let argv = CommandLine.arguments.contains("--smoke")
        let envOverride = ProcessInfo.processInfo
            .environment[DeviceTermEnv.daemonSock]?.isEmpty == false
        return argv && envOverride
    }

    /// Mirror of the daemon's `RPCMethodError.unauthorizedCode`
    /// (`Sources/Daemon/RPCMethodError.swift`): the wire code for
    /// "session-scoped method on an unauthenticated connection." The
    /// daemon module isn't linkable from the GUI, so the value is
    /// mirrored here with this pointer to its source of truth.
    private static let unauthorizedConnectionCode = -32_001
    /// The daemon's "provenance not ready" code: retryable, distinct from a
    /// hard `-32001`. It surfaces when a transient XPC signature-validation
    /// blip leaves the peer momentarily unverified (an anchor-less session then
    /// has no exact-owner fallback), when a terminal anchor hasn't landed yet,
    /// or while a fresh daemon still awaits its restore batch (an unknown
    /// session is retryable until the barrier releases). The GUI retries
    /// briefly rather than treating it as terminal (which
    /// would freeze a pane mirror), and (unlike `-32001`) never prunes the
    /// credential.
    private static let notReadyConnectionCode = -32_002
    private static let maxNotReadyRetries = 10
    /// Methods whose work is inherently long, given
    /// `slowRequestDeadlineNanos` instead of `requestDeadlineNanos`. The
    /// lifecycle calls block inside CoreSimulator, and `pane.create` acquires
    /// a pane backend. Keyed by method rather than by call site so the
    /// allowance follows the call wherever it's issued from.
    private static let slowMethods: Set<RPCMethod> = [
        .deviceBoot,
        .deviceShutdown,
        .paneCreate
    ]
    /// Calls that mint daemon state, so abandoning their reply loses the only
    /// name for what they made. They are exempt from `bounded` (which cancels
    /// the loser of its race) and bounded by their caller through
    /// `Deadline.wait`, which lets the call finish and reconciles a late
    /// reply. The two attaches are bounded by the Router's
    /// `attachDeadlineNanos` instead.
    private static let selfReconcilingMethods: Set<RPCMethod> = [
        .sessionCreate,
        .deviceAttach,
        .physicalDeviceAttach
    ]
    /// Unanswered calls in a row before the helper is declared unresponsive.
    ///
    /// Two consecutive unanswered calls, with any reply resetting the count.
    ///
    /// A heuristic, not proof of a wedge. One call can legitimately outlast
    /// its bound, and the bounds are not uniform (the lifecycle methods carry
    /// a much larger one), so a single expiry says too little to interrupt
    /// anyone over. Two in a row with nothing answered between them is worth
    /// offering a restart for, which is a question rather than an action.
    ///
    /// A silent helper reaches it without the user doing anything, because
    /// each tab's discovery poll issues a `device.list` under the ordinary
    /// bound: about half a minute for one idle tab (the poll is serial, so its
    /// expiries land a bound apart), sooner with more tabs or any traffic of
    /// the user's own.
    static let unresponsiveTimeoutThreshold = 2

    private let xpcConnection: XPCDaemonConnection
    private var udsConnection: UDSDaemonConnection?
    private var transport: DaemonTransport
    private(set) var supportsLiveTouchInput = false
    private(set) var supportsMultitouchInput = false
    /// Cached credentials for GUI sessions believed live, ordered by most
    /// recent successful authentication (most-recent last). The connection
    /// authenticates as one session at a time, and after a reconnect none is
    /// authenticated yet, so a session-scoped call that fails because the
    /// connection was re-established (daemon idle-exit/respawn or XPC
    /// interruption resets the daemon-side `RPCConnection` to unauthenticated)
    /// re-authenticates with one of these *live* credentials and retries. The
    /// daemon's `.session` scope requires only
    /// *an* authenticated session, not a specific one, so any live
    /// credential re-authenticates the connection for every surviving pane.
    /// Tracked as a list (not a single slot) so closing the most-recently
    /// authenticated session doesn't strand a later reconnect on a now-
    /// deleted credential: `closeSession` drops it, and reauth prunes any
    /// credential the daemon rejects (a close whose response was lost still
    /// deleted the session), falling back to an older live credential.
    /// Empty before the first successful authentication, after all cached
    /// sessions close successfully, or after reauthentication rejects and
    /// prunes every cached credential.
    private var liveSessions: [SessionAuthenticateParams] = []
    /// Observers notified after a reconnect re-establishes the connection, so
    /// GUI terminal panes can re-bind their identities (the daemon's anchor
    /// store is in-memory and lost on its restart). Keyed by token so a closing
    /// tab removes its own entry: the registry never accumulates dead
    /// closures. See `ReconnectObserving`.
    private var reconnectObservers: [ReconnectObserverToken: @MainActor () -> Void] = [:]
    /// Called after a reconnect's version handshake succeeds, to drive inventory
    /// re-supply through the `InventorySyncCoordinator`, the sole caller of
    /// `session.restoreBatch`, which is now both restart restoration AND ongoing
    /// authoritative inventory reconciliation. Set by `AppDelegate`. The
    /// coordinator fires the terminal-rebind observers itself, on its first
    /// verified sync of the generation (so rebinds still wait for a successful
    /// restoration), which is why this is fire-and-forget.
    var onReconnected: (@MainActor () -> Void)?
    /// Monotonic reconnect counter. Bumped just before the reconnect
    /// inventory re-supply runs,
    /// so a restore still retrying from an earlier reconnect can detect that a
    /// newer reconnect superseded it and bail (its inventory would be stale).
    private(set) var reconnectGeneration = 0
    /// Monotonic per-send revision for `session.restoreBatch`, paired
    /// server-side with the connection epoch so a same-connection retry with a
    /// changed inventory strictly dominates the earlier attempt. Never rewinds.
    private var restoreRevision = 0
    /// Monotonic per-send revision shared by `orchestrator.grant` and
    /// `.revoke`, paired server-side with the connection epoch for
    /// `(epoch, revision)` last-write-wins ordering. Grant and revoke draw from
    /// the SAME counter so a later revoke always dominates an earlier grant (and
    /// vice versa). Lives on the single shared client, so it stays monotonic
    /// across reconnects and never rewinds: a reissue after reconnect gets a
    /// value that dominates the pre-reconnect grant (and the new connection
    /// epoch already dominates the old one regardless).
    private var grantRevision = 0
    /// Monotonic per-send revision for the attach verbs, so the daemon can
    /// refuse one this client has already superseded. Lives on the single
    /// shared client (like `grantRevision`), so it stays monotonic across
    /// reconnects and never rewinds. Needed because a timed-out attach keeps
    /// running: its retry and it are both in flight, the daemon may handle
    /// them in either order, and without this the older one could re-admit the
    /// pane to an identity the GUI never learns and then silently refuse every
    /// close it sends.
    private var attachRevision: UInt64 = 0
    /// Invoked (main actor) after the client has handled a definite wire-version
    /// mismatch: the daemon was replaced by an incompatible build (e.g. a
    /// Sparkle update). By the time this fires the client has already attempted
    /// to shut the incompatible daemon down; the `VersionMismatchOutcome`
    /// reports whether the answering daemon confirmed acceptance of the
    /// shutdown request; it does not prove process termination, so `AppDelegate`
    /// can surface an honest message. Set by `AppDelegate` to route both the
    /// startup and the auto-reconnect mismatch through the same remediation.
    /// When nil the client still attempts the shutdown but has no surface to
    /// report it.
    var onVersionMismatch: (@MainActor (VersionMismatchOutcome) -> Void)?
    /// Invoked (main actor) once `unresponsiveTimeoutThreshold` calls in a row
    /// have gone unanswered, and on every unanswered call after that until one
    /// is answered. It reports a condition rather than an edge: a helper that
    /// never answers again produces nothing but expiries, so an observer told
    /// only about the first would have one chance to act on something that is
    /// still true minutes later. Deciding when to act on repeats is the
    /// observer's job, because only it knows what it is already showing. Set
    /// by `AppDelegate` to raise the restart prompt. Reporting changes nothing
    /// about request execution: the client keeps issuing and bounding calls.
    /// Carries the transport connection the unanswered calls were going to, so
    /// a restart raised from it can be fenced to that connection rather than
    /// to whatever is current by the time the user answers a prompt.
    var onUnresponsive: (@MainActor (Int) -> Void)?
    /// Calls that have reached their deadline with no answer in between.
    private var consecutiveTimeouts = 0
    /// The transport's connection generation as last observed, updated when a
    /// peer is installed rather than read back on demand. Held so the
    /// unresponsive signal can name a connection synchronously: the transport
    /// is an actor, so reading it is a hop, and a hop is exactly long enough
    /// for the connection being diagnosed to be replaced by another.
    ///
    /// Readable so a caller with no call to hang a generation off can still
    /// name the live connection. Anything reporting a call's outcome takes the
    /// generation from that call's own `…WithGeneration` form instead, which
    /// captures it with the answer rather than after it.
    private(set) var connectionGeneration = 0
    /// Latches once a definite version mismatch has been handled, so the XPC
    /// invalidation caused by the `daemon.shutdown` we send (which re-fires the
    /// reconnect handler → re-detects the mismatch) cannot drive a second
    /// remediation, a restore against the dying daemon, or an unbounded
    /// reconnect loop. Remediation ends in quit, so at-most-once for the
    /// client's lifetime is the intended (and strictest) reading of
    /// "at most once per reconnect generation".
    private var versionMismatchHandled = false
    /// How long `shutdownIncompatibleDaemon()` waits for the `daemon.shutdown`
    /// ack before reporting the outcome as indeterminate. A daemon that answers
    /// `ping` but never replies to shutdown must not wedge startup/reconnect.
    /// 5s is far more than the immediate ack needs; overridden small in tests.
    var shutdownAckTimeoutNanos: UInt64 = 5_000_000_000
    /// Upper bound on a single transport round-trip for the ordinary methods.
    /// Not an SLA: every one of these answers in milliseconds when the daemon
    /// is healthy, so the only thing this number decides is how long the GUI
    /// waits on a daemon that has stopped answering (a blocking CoreSimulator
    /// call on its actor, a `kill -STOP`) before turning the wait into an
    /// error the user can act on. Chosen to sit well above the latency a busy
    /// daemon shows; it can't tell busy from wedged, it can only outlast the
    /// former. Tests shorten it.
    var requestDeadlineNanos: UInt64 = 15_000_000_000
    /// The same bound for the methods in `slowMethods`, which legitimately run
    /// far longer than a round-trip.
    var slowRequestDeadlineNanos: UInt64 = 120_000_000_000
    /// Test-only override for the `request` half of the transport.
    /// When non-nil, `rawRequest` routes through it instead of the
    /// `transport` enum, so a test can script responses (e.g. the
    /// -32001-then-success reconnect path) without a live socket.
    /// Always nil in production. The subscribe paths still use the
    /// enum, so the unconnected `xpcConnection` is constructed even
    /// under injection (constructing it touches no socket).
    private let injectedRequestTransport: DaemonRequestTransport?

    /// Test-only override for the subscribe path. When non-nil,
    /// `rawSubscribePane` routes through it instead of the `transport`
    /// enum, so a test can script the -32001-then-success subscribe
    /// reconnect path without a live socket. Always nil in production.
    private let injectedSubscribeTransport: DaemonSubscribeTransport?

    init(machServiceName: String = MachServiceName.daemon) {
        let xpc = XPCDaemonConnection(machServiceName: machServiceName)
        self.xpcConnection = xpc
        self.transport = .xpc(xpc)
        self.injectedRequestTransport = nil
        self.injectedSubscribeTransport = nil
    }

    /// Test seam: inject a scripted `request` transport (and optionally a
    /// scripted subscribe transport). The enum/subscribe fields still need
    /// a concrete `XPCDaemonConnection`, constructed unconnected (no socket
    /// touched), but every `request` is routed through `requestTransport`
    /// and, when supplied, every `subscribePane` through
    /// `subscribeTransport`.
    init(
        injecting requestTransport: DaemonRequestTransport,
        subscribe subscribeTransport: DaemonSubscribeTransport? = nil,
        machServiceName: String = MachServiceName.daemon
    ) {
        let xpc = XPCDaemonConnection(machServiceName: machServiceName)
        self.xpcConnection = xpc
        self.transport = .xpc(xpc)
        self.injectedRequestTransport = requestTransport
        self.injectedSubscribeTransport = subscribeTransport
    }

    // MARK: - Shell env path resolution
    //
    // The GUI moved to XPC but the CLI (and the shim) still talk to
    // the daemon over UDS: the daemon vends both transports. Tab
    // shell environments need the UDS path so `deviceterm-cli` can
    // connect from inside the shell. `socketPath()` is the
    // path-resolution helper; the GUI itself never opens the socket.

    /// Resolve the UDS path the daemon vends for the CLI / shim.
    /// Honors `DEVICETERM_DAEMON_SOCK` overrides; defaults to
    /// `~/Library/Application Support/deviceterm/daemon.sock`.
    static func socketPath() -> String {
        if let env = ProcessInfo.processInfo.environment[DeviceTermEnv.daemonSock],
            !env.isEmpty {
            return env
        }
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return support?
            .appendingPathComponent("deviceterm/daemon.sock")
            .path ?? "/tmp/deviceterm-daemon.sock"
    }

    // MARK: - Connection lifecycle (instance methods)

    /// Open the daemon connection (XPC in production, UDS in
    /// smoke-mode-only fallback) then run the wire-version
    /// handshake.
    func connect() async throws {
        if Self.isSmokeMode {
            let socketPath = Self.socketPath()
            let uds = try await UDSDaemonBringup.bringUp(socketPath: socketPath)
            self.udsConnection = uds
            self.transport = .uds(uds)
        } else {
            // Drive terminal re-binding off the ACTUAL transport reconnection,
            // set before the first connect so every later reconnect fires it,
            // even one triggered only by the always-running `.validatedGUI`
            // `app.commands` subscription (a terminal-only tab never makes a
            // session-scoped call, so the `-32001` reauth path alone would
            // leave it permanently anchorless).
            await xpcConnection.setReconnectHandler { [weak self] connection in
                Task { @MainActor in
                    guard let self else { return }
                    // The transport's own generation, as of the connection
                    // being installed. Held so a call that goes unanswered can
                    // name the connection it was talking to without an actor
                    // hop, which is the whole point: reading it back later
                    // returns whatever is current then, not what was
                    // diagnosed.
                    self.connectionGeneration = connection
                    // Bump the generation so a restore still retrying from an
                    // earlier reconnect can observe that it was superseded and
                    // bail.
                    self.reconnectGeneration += 1
                    // Logged to make a superseded handshake cycle visible.
                    // Correlate timelines on the transport's
                    // `connectionGeneration` instead: this counter trails it by
                    // a scheduling hop.
                    reconnectLog.info(
                        """
                        handshake generation=\
                        \(self.reconnectGeneration, privacy: .public)
                        """
                    )
                    await self.runReconnectHandshake(generation: self.reconnectGeneration)
                }
            }
            await xpcConnection.connect()
            // The reconnect handler covers every later peer, but not the
            // first one: it deliberately doesn't fire for the initial
            // connect. Without seeding here a helper that wedges on its first
            // connection would be diagnosed against generation 0, and the
            // fence would refuse to stop the very peer it was raised about.
            connectionGeneration = await xpcConnection.currentGeneration
        }
        // Startup handshake. A definite mismatch is surfaced INSIDE
        // `versionHandshake` (which captures the generation and attempts the
        // incompatible-daemon shutdown), then rethrown: AppDelegate's launch
        // catch recognizes `versionMismatch` and skips the generic alert.
        try await versionHandshake()
    }

    /// Re-run the wire-version handshake after a transport reconnect. An
    /// auto-reconnect can land on a daemon replaced by a Sparkle update whose
    /// wire contract differs, and the startup handshake would not catch a
    /// mid-session swap. ONLY a definite version *mismatch* routes to
    /// remediation and skips restore; a transient failure (the daemon still
    /// coming up after its respawn, a transport blip) is retried DURABLY with
    /// capped backoff: never mistaken for an incompatible helper, never
    /// abandoned, so restoration isn't stranded. The loop exits only on success,
    /// a definite mismatch, cancellation (app teardown), or supersession by a
    /// newer reconnect (which runs its own handshake + restore). Internal so a
    /// hermetic test can drive it directly with a scripted transport.
    func runReconnectHandshake(generation: Int) async {
        // A definite mismatch has already been handled: the app is quitting and
        // the `daemon.shutdown` we sent invalidated the connection, re-firing
        // this handler. Do NOT handshake, restore, or (via demand-launch) revive
        // the replaced daemon while the quit alert is up.
        if versionMismatchHandled { return }
        var handshakeBackoff: UInt64 = 200_000_000  // 200ms, capped 5s
        while true {
            if Task.isCancelled { return }
            // A newer reconnect superseded this cycle: let it drive.
            if reconnectGeneration != generation { return }
            // A mismatch may have been handled by a concurrent path since the
            // last suspension; stop before restoring against a dying daemon.
            if versionMismatchHandled { return }
            do {
                try await versionHandshake()
                break
            } catch let error as DaemonClientError where error.isVersionMismatch {
                // Definite incompatibility: already surfaced inside
                // `versionHandshake` (with the generation fence). Stop: never
                // restore against the incompatible daemon.
                return
            } catch {
                do {
                    try await Task.sleep(nanoseconds: handshakeBackoff)
                } catch {
                    return
                }
                handshakeBackoff = min(handshakeBackoff * 2, 5_000_000_000)
            }
        }
        // Drive inventory re-supply through the coordinator (the sole
        // `restoreBatch` caller). A fresh daemon starts with no sessions;
        // `session.bindTerminal` for an unrestored session fails
        // `.sessionNotLive`, so the coordinator fires the terminal-rebind
        // observers only after its first VERIFIED sync of this generation:
        // rebinds wait for a successful restoration.
        //
        // Restoration is not a full transport barrier. The daemon barrier
        // protects `session.authenticate` (unknown sessions stay retryable
        // `notReady`, so a valid credential is never pruned). Normal
        // daemon-wide and validated-GUI calls are not gated on generation
        // restoration and may race it: they may fail or observe pre-restoration
        // state, a deliberate fail-closed availability limitation.
        //
        // Final guard: if a definite mismatch was handled while this handshake
        // ran (e.g. it succeeded against a freshly demand-launched updated
        // daemon), do NOT restore: the app is quitting for the user to relaunch.
        if versionMismatchHandled { return }
        onReconnected?()
    }

    /// Handle a definite daemon wire-version mismatch exactly once for this
    /// client's lifetime (see `versionMismatchHandled`): attempt to shut the
    /// incompatible daemon down so the next launch can't reconnect to it, then
    /// report the outcome to `onVersionMismatch`. Idempotent re-entry (the
    /// shutdown's own XPC invalidation re-fires the reconnect handler) is
    /// dropped.
    func surfaceVersionMismatch(_ mismatch: DaemonClientError, generation: Int) async {
        guard !versionMismatchHandled else { return }
        versionMismatchHandled = true
        // ALWAYS terminally quiesce the transport (refuse + fail in-flight +
        // finish subscriptions + drop notifications) so nothing keeps running
        // over the connection, even a replacement, which will never complete a
        // reconnect handshake now that remediation has latched. The return says
        // only whether the connection is STILL the pinned instance that answered
        // the mismatched ping: if so, send the bootstrap shutdown to it; if it
        // was replaced, that incompatible instance is already gone, so DON'T
        // shut down the current, different (possibly-updated) daemon: just
        // surface so the user relaunches a matching GUI.
        let pinned = await xpcConnection.markIncompatible(expectedGeneration: generation)
        let outcome: VersionMismatchOutcome
        if pinned {
            outcome = await attemptIncompatibleDaemonShutdown(mismatch)
        } else {
            outcome = VersionMismatchOutcome(
                mismatch: mismatch,
                shutdown: .indeterminate(
                    "the incompatible daemon was replaced before it could be stopped"
                )
            )
        }
        onVersionMismatch?(outcome)
    }

    private func attemptIncompatibleDaemonShutdown(
        _ mismatch: DaemonClientError
    ) async -> VersionMismatchOutcome {
        if Self.isSmokeMode {
            // Smoke runs over UDS, where `.validatedGUI` `daemon.shutdown` is
            // refused; we can't stop the daemon and must not claim to.
            return VersionMismatchOutcome(
                mismatch: mismatch,
                shutdown: .indeterminate(
                    "the helper runs over the smoke UDS transport, which can't "
                        + "request shutdown"
                )
            )
        }
        do {
            try await shutdownIncompatibleDaemon()
            return VersionMismatchOutcome(mismatch: mismatch, shutdown: .confirmed)
        } catch {
            return VersionMismatchOutcome(mismatch: mismatch, shutdown: .indeterminate("\(error)"))
        }
    }

    /// Ask the incompatible daemon to terminate itself and await its ack. Sent
    /// precisely *because* the wire versions differ, so it must not depend on a
    /// same-version handshake: `daemon.shutdown` (like `daemon.ping`) is a
    /// stable bootstrap/recovery method whose name and `{ok}` shape are held
    /// across wire versions. `.validatedGUI` on the daemon: the GUI's audit
    /// token is the authority, so no session or cap rides on the wire. Throws if
    /// the ack doesn't arrive (the caller reports an honest failure).
    func shutdownIncompatibleDaemon() async throws {
        // Bound the wait: a daemon that answered `ping` but never replies to
        // `daemon.shutdown` must not block the remediation (and thus the failure
        // alert / startup / reconnect) forever. On expiry the ack is unknown, so
        // the caller reports it as indeterminate.
        let timeoutNanos = shutdownAckTimeoutNanos
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [self] in try await request(method: .daemonShutdown, params: nil) }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanos)
                throw DaemonClientError.shutdownTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DaemonClientError.shutdownTimedOut
            }
            return first
        }
        let ack = try decode(DaemonShutdownAck.self, data)
        guard ack.ok else { throw DaemonClientError.shutdownNotAcknowledged }
    }

    /// Stop the helper process this connection is talking to. See
    /// `XPCDaemonConnection.terminateCurrentPeer` for the pid's provenance and
    /// what each outcome does and doesn't claim.
    ///
    /// The smoke UDS fallback has no XPC peer, so it reports `.alreadyGone`: over
    /// that transport the daemon is the harness's to stop, not the GUI's.
    func terminateHelper(expectedGeneration: Int?) async -> HelperTerminationOutcome {
        await xpcConnection.terminateCurrentPeer(expectedGeneration: expectedGeneration)
    }

    /// Try to reconnect immediately after the helper was stopped.
    ///
    /// One ping is the whole attempt: the send is what launchd demand-launches
    /// the replacement for, and a reply drives the reconnect handshake and,
    /// with it, session restore and pane recovery. A failed ping is swallowed
    /// rather than retried here, because the back-channel drain and every pane
    /// subscription are already retrying on their own backoff; succeeding only
    /// means recovery starts now instead of at whatever those have reached.
    func reconnect() async {
        _ = try? await ping()
    }

    /// Tear down the connection. Called by App quit paths + tests.
    func disconnect() async {
        await xpcConnection.disconnect()
        udsConnection?.close()
    }

    func ping() async throws -> DaemonPingResponse {
        let data = try await request(method: .daemonPing, params: nil)
        return try decode(DaemonPingResponse.self, data)
    }

    func createSession(
        label: String?,
        name: String?,
        role: SessionRole,
        initialPrivate: Bool = false
    ) async throws -> SessionCreateResponse {
        // `compactMapValues { $0 }` strips nil entries before JSON
        // serialization so the wire shape carries optional fields
        // only when present: older daemons that don't know a field
        // still decode because they ignore unknown keys, and a nil
        // doesn't explicitly encode as a null. `role` is always
        // sent; a pre-role daemon that ignores it falls back to
        // minting an agent session (defaults align).
        //
        // The daemon captures the owner identity from the XPC peer's audit
        // token server-side (the exact-owner provenance arm and the
        // orphan-liveness pid), so no owner pid rides on the wire: a caller
        // can't name a pid it doesn't own.
        // `initialPrivate` is sent only when true, so an ordinary public
        // create carries no extra key (a nil is stripped by
        // `compactMapValues`, and the daemon reads absent as false).
        let params = try JSONSerialization.data(
            withJSONObject: [
                "label": label as Any,
                "name": name as Any,
                "role": role.rawValue,
                "initialPrivate": initialPrivate ? true : nil
            ].compactMapValues { $0 },
            options: []
        )
        // Bounded here rather than in `rawRequest`, because the capability in
        // this reply leaves the daemon exactly once: cancelling the wait would
        // strand a session nobody can name or close, and an omitting
        // `session.restoreBatch` can't reap it on the same connection (a live
        // create's assertion deliberately outranks a restore baseline at that
        // epoch). So let the call finish and close what it made. Nothing else
        // can be using it: the GUI is the only party that ever sees this
        // capability, and it is dropping it here.
        let data: Data
        do {
            data = try await Deadline.wait(
                nanos: requestDeadlineNanos,
                expired: DaemonClientError.timedOut(method: RPCMethod.sessionCreate.rawValue),
                late: { [weak self] late in await self?.closeUnclaimedSession(late) },
                work: { [self] in try await request(method: .sessionCreate, params: params) }
            )
        } catch {
            // `bounded` does this for the calls it wraps; this one is bounded
            // here instead, and opening a tab is exactly the thing a user
            // tries when the helper has gone quiet. The expiry is raised by
            // the deadline rather than the inner call, so only this frame
            // sees it.
            noteHelperFailure(error)
            throw error
        }
        let response = try decode(SessionCreateResponse.self, data)
        // Auto-authenticate the long-lived GUI ↔ daemon connection so
        // session-scoped methods invoked from the GUI (panes.list,
        // device.attach, …) pass the dispatcher's auth gate.
        do {
            try await authenticateConnection(
                sessionId: response.sessionId,
                capability: response.capability
            )
        } catch {
            // The session exists and this reply holds its only capability, but
            // the caller is about to get an error instead of it, so nothing
            // will ever name it again. Discard it here rather than let the
            // failure strand it.
            await discardSession(response)
            throw error
        }
        await refreshCapabilities()
        return response
    }

    /// Close a session whose `session.create` reply arrived after its caller
    /// gave up waiting.
    private func closeUnclaimedSession(_ data: Data) async {
        guard let response = try? decode(SessionCreateResponse.self, data) else { return }
        await discardSession(response)
    }

    /// Close a session the caller will never see, so it doesn't linger as a
    /// tab nobody opened.
    ///
    /// `.shutdown` because the session was never handed to a tab, so nothing
    /// it owns is wanted either. Best-effort, and "best" is the honest word:
    /// if the close can't be confirmed it may still have landed daemon-side,
    /// and if it genuinely didn't, the session waits for the next connection
    /// epoch (a reconnect or a restart) to clear it.
    private func discardSession(_ response: SessionCreateResponse) async {
        do {
            try await closeSession(
                sessionId: response.sessionId,
                capability: response.capability,
                mode: .shutdown
            )
        } catch let DaemonClientError.daemon(code, _)
            where code == Self.unauthorizedConnectionCode {
            // `session.close` is session-scoped, so it's refused before it
            // reaches its handler when the connection has no authenticated
            // principal, which is exactly the case when the session being
            // discarded is the FIRST one this connection ever created. The
            // reply we're cleaning up carries the only capability that exists
            // for it, so authenticate with that and close it properly.
            //
            // The connection is then briefly authenticated as a session that
            // is immediately closed. That resolves itself: the next
            // session-scoped call's own `-32001` walks `liveSessions` for a
            // live credential, and `closeSession` has already dropped this
            // dead one from that list.
            do {
                try await authenticateConnection(
                    sessionId: response.sessionId,
                    capability: response.capability
                )
            } catch {
                // A refused capability is the one genuinely unrecoverable
                // shape, so it's reported rather than swallowed. Every way to
                // remove a session is session-scoped; this connection holds no
                // other principal to borrow (that is why the close was refused
                // in the first place); and the one credential that could
                // authorize it is the one just rejected. An omitting
                // `restoreBatch` can't reap it on this epoch either, so the
                // session really does survive until the next one.
                let detail = String(describing: error)
                sessionLog.error(
                    """
                    could not discard an unclaimed session: no authenticated \
                    principal, and its own capability was refused \
                    (\(detail, privacy: .public))
                    """
                )
                return
            }
            await reportUnconfirmedClose(of: response)
        } catch {
            await reportUnconfirmedClose(of: response)
        }
    }

    /// Retry the close now that a principal exists, and describe the outcome
    /// honestly if it still can't be confirmed.
    ///
    /// "Unconfirmed" rather than "failed": a close that times out or loses its
    /// transport may well have landed daemon-side, exactly like any other
    /// abandoned mutation. If it didn't, the session waits for the next
    /// connection epoch.
    private func reportUnconfirmedClose(of response: SessionCreateResponse) async {
        do {
            try await closeSession(
                sessionId: response.sessionId,
                capability: response.capability,
                mode: .shutdown
            )
        } catch {
            let detail = String(describing: error)
            sessionLog.error(
                """
                could not confirm the close of an unclaimed session; the \
                request may still have completed daemon-side \
                (\(detail, privacy: .public))
                """
            )
        }
    }

    /// Send `session.authenticate` over the live connection. Called
    /// implicitly by `createSession` so callers never thread auth
    /// themselves.
    private func authenticateConnection(
        sessionId: String,
        capability: String
    ) async throws {
        let authParams = SessionAuthenticateParams(
            sessionId: sessionId,
            cap: capability
        )
        let params = try JSONEncoder().encode(authParams)
        _ = try await request(method: .sessionAuthenticate, params: params)
        // Remember the session so a post-reconnect -32001 can re-auth with a
        // live credential and retry transparently. De-dup by sessionId and
        // move it to the end so the most-recently authenticated live session
        // is preferred for reauth.
        liveSessions.removeAll { $0.sessionId == authParams.sessionId }
        liveSessions.append(authParams)
    }

    /// Bind a session to its terminal's kernel identity. The GUI reads the
    /// pane surface's foreground pid + tty (`TerminalSurface.terminalIdentity`)
    /// and sends them here so the daemon can derive and store the terminal
    /// anchor, the "terminal" provenance arm that lets an in-tab CLI process
    /// authenticate as the pane's session while an out-of-tab cap thief cannot.
    /// `.validatedGUI`-scoped: the audit token is the authority, so no
    /// `(sessionId, cap)` rides on the wire. Idempotent: re-binding the same
    /// terminal is a daemon-side no-op, so a retry (or a reconnect republish)
    /// is safe.
    func bindTerminal(
        sessionId: String,
        foregroundPid: Int32,
        ttyName: String
    ) async throws {
        let params = try JSONEncoder().encode(
            SessionBindTerminalParams(
                sessionId: sessionId,
                foregroundPid: foregroundPid,
                ttyName: ttyName
            )
        )
        _ = try await request(method: .sessionBindTerminal, params: params)
    }

    /// Re-authenticate the connection after a reconnect reset its daemon-side
    /// auth. Tries cached credentials newest-first, pruning any the daemon
    /// rejects with `unauthorizedConnectionCode` (its session was deleted,
    /// e.g. a `session.close` whose response never arrived so `closeSession`
    /// couldn't prune it) and falling back to an older live credential.
    /// Returns `true` once one authenticates; `false` only when every cached
    /// credential has been pruned (none remain, the caller surfaces the
    /// original error). A non-authentication failure (a transport drop) is
    /// **propagated**, not swallowed: it's no evidence the session is dead,
    /// and the caller must see the real error to classify it (a transport
    /// drop is retryable; masking it as the original -32001 would make the
    /// pane's reconnect loop treat a transient drop as terminal).
    private func reauthenticateAfterReconnect() async throws -> Bool {
        while let candidate = liveSessions.last {
            do {
                try await authenticateConnection(
                    sessionId: candidate.sessionId,
                    capability: candidate.cap
                )
                // NOTE: re-binding is NOT fired here. A reconnect that only the
                // always-running `.validatedGUI` `app.commands` subscription
                // recovers never reaches this `-32001` reauth path, so the
                // reconnect signal is driven directly off the XPC transport
                // (`XPCDaemonConnection.setReconnectHandler` → `notifyReconnect`)
                // instead. See `connect()`.
                return true
            } catch let DaemonClientError.daemon(code, _)
                where code == Self.unauthorizedConnectionCode {
                liveSessions.removeAll { $0.sessionId == candidate.sessionId }
            }
        }
        return false
    }

    func addReconnectObserver(_ handler: @escaping @MainActor () -> Void) -> ReconnectObserverToken {
        let token = ReconnectObserverToken(id: UUID())
        reconnectObservers[token] = handler
        return token
    }

    func removeReconnectObserver(_ token: ReconnectObserverToken) {
        reconnectObservers[token] = nil
    }

    /// Fan the reconnect signal out to every registered observer (each tab's
    /// `rebindAllTerminals`). Wired to the XPC transport's reconnect handler in
    /// `connect()`. Internal (not private) so a hermetic test can drive the
    /// fan-out without standing up a real XPC reconnect.
    func notifyReconnect() {
        for observer in reconnectObservers.values { observer() }
    }

    private func refreshCapabilities() async {
        // No payload creds: `daemon.capabilities` derives authority from the
        // (already authenticated) connection, not the request body.
        guard
            let data = try? await request(method: .daemonCapabilities, params: nil),
            let capabilities = try? decode(DaemonCapabilitiesResponse.self, data)
        else {
            supportsLiveTouchInput = false
            supportsMultitouchInput = false
            return
        }
        supportsLiveTouchInput = capabilities.allowedMethods
            .contains(RPCMethod.paneInputTouch.rawValue)
        supportsMultitouchInput = capabilities.allowedMethods
            .contains(RPCMethod.paneInputMultitouch.rawValue)
    }

    /// `session.close`: `mode` is "detach" (default; sims keep
    /// running) or "shutdown". Existing daemon method; no schema
    /// change. Result is the `{ok:true}` ack, which we don't inspect.
    func closeSession(
        sessionId: String,
        capability: String,
        mode: PaneCloseMode = .detach
    ) async throws {
        let params = try JSONSerialization.data(
            withJSONObject: [
            "sessionId": sessionId,
            "cap": capability,
            "mode": mode.rawValue
            ]
            )
        _ = try await request(method: .sessionClose, params: params)
        // The daemon deleted this session; drop its credential so a later
        // reconnect never replays a dead session: replaying one would fail
        // the reauth and, with it, every surviving pane's resubscribe.
        liveSessions.removeAll { $0.sessionId == sessionId }
    }

    /// `session.setPrivateBatch`: atomically flip the privacy flag for
    /// a tab's terminal-pane sessions, subject to daemon-side
    /// `(epoch, revision)` last-write-wins. `.validatedGUI`-scoped, so no
    /// cap on the wire; over the `--smoke` UDS fallback the daemon refuses
    /// it with `roleViolation`. Returns `SessionSetPrivateBatchResult`
    /// `{applied, revision, isPrivate}`. `applied: false` means the batch
    /// was stale (a higher-key write won) and nothing mutated.
    func setPrivateBatch(
        sessionIds: [String],
        isPrivate: Bool,
        revision: Int
    ) async throws -> SessionSetPrivateBatchResult {
        let params = try JSONEncoder().encode(
            SessionSetPrivateBatchParams(
            sessionIds: sessionIds,
            isPrivate: isPrivate,
            revision: revision
        )
            )
        let data = try await request(method: .sessionSetPrivateBatch, params: params)
        return try decode(SessionSetPrivateBatchResult.self, data)
    }

    /// `session.setDisplayTitle`: publish the tab's live label so
    /// `tabs.list` can serve it in place of the static name stamped at
    /// `session.create`. What lands is the normalized, bounded form, and
    /// only when it says something `name` does not; readers fall back to
    /// `name` otherwise. `.validatedGUI`-scoped, so no cap on the wire;
    /// over the `--smoke` UDS fallback the daemon refuses it with
    /// `roleViolation` and the publisher stops.
    ///
    /// The title is normalized here as well as daemon-side: an OSC title is
    /// unbounded caller-controlled text, and bounding it before encoding
    /// keeps a hostile title from becoming a giant XPC payload the daemon
    /// only trims after receiving. A title that normalizes to nil is sent
    /// as an explicit clear, never skipped.
    func setDisplayTitle(sessionId: String, title: String?) async throws {
        let params = try JSONEncoder().encode(
            SessionSetDisplayTitleParams(
                sessionId: sessionId,
                title: DisplayTitleNormalizer.normalize(title)
            )
        )
        _ = try await request(method: .sessionSetDisplayTitle, params: params)
    }

    /// `orchestrator.grant`: `.validatedGUI`-scoped (the GUI's audit token is
    /// the authority; no cap on the wire). Stamps a fresh monotonic revision
    /// per send so the daemon's `(epoch, revision)` ordering can reject a stale
    /// retry; callers never manage the revision. Issued after a terminal binds
    /// (and reissued on reconnect once it rebinds), so the grant rests on a
    /// live, terminal-bound session an in-tab CLI can authenticate as.
    @discardableResult
    func grantOrchestrator(sessionIds: [UUID]) async throws -> OrchestratorGrantResult {
        grantRevision += 1
        let params = try JSONEncoder().encode(
            OrchestratorGrantParams(sessionIds: sessionIds, revision: grantRevision)
        )
        let data = try await request(method: .orchestratorGrant, params: params)
        return try decode(OrchestratorGrantResult.self, data)
    }

    /// Re-supply the daemon's COMPLETE session inventory after a daemon-only
    /// restart (`session.restoreBatch`). `.validatedGUI`-scoped: the audit
    /// token is the authority, so no cap rides as a separate factor (the bearer
    /// cap inside each entry is what the daemon re-derives the verifier from).
    /// Over the `--smoke` UDS fallback the daemon refuses it with
    /// `roleViolation`; the caller treats a refusal as "restore unsupported on
    /// this transport" (daemon-restart recovery is an XPC-only feature).
    func restoreBatch(sessions: [RestoredSession]) async throws -> SessionRestoreBatchResult {
        // Allocate a fresh, monotonically increasing revision per SEND (each
        // durable retry included), so a same-connection retry carrying a changed
        // inventory strictly dominates the earlier attempt daemon-side. The
        // counter lives on the single shared client, so it stays monotonic
        // across reconnects too.
        restoreRevision += 1
        let params = try JSONEncoder().encode(
            SessionRestoreBatchParams(sessions: sessions, revision: restoreRevision)
        )
        let data = try await request(method: .sessionRestoreBatch, params: params)
        return try decode(SessionRestoreBatchResult.self, data)
    }

    func privacySnapshot(
        sessionIds: [String],
        revision: Int
    ) async throws -> SessionPrivacySnapshotResult {
        let params = try JSONEncoder().encode(
            SessionPrivacySnapshotParams(sessionIds: sessionIds, revision: revision)
        )
        let data = try await request(method: .sessionPrivacySnapshot, params: params)
        return try decode(SessionPrivacySnapshotResult.self, data)
    }

    /// `device.list`: `scope` is "owned" or "all". Existing daemon
    /// method; no schema change. Returns the bare-array result.
    func deviceList(scope: DeviceListScope) async throws -> [DeviceListEntry] {
        let params = try JSONSerialization.data(withJSONObject: ["scope": scope.rawValue])
        let data = try await request(method: .deviceList, params: params)
        return try decode([DeviceListEntry].self, data)
    }

    /// `device.list`, plus the connection that answered it. The owned-roster
    /// mirror is the caller that needs it: its whole job is to tell a
    /// replacement helper's "nothing is owned" from the roster it is holding
    /// to restore, and misattributing one helper's answer to another is the
    /// error it cannot survive.
    func deviceListWithGeneration(
        scope: DeviceListScope
    ) async throws -> (entries: [DeviceListEntry], generation: Int) {
        let params = try JSONSerialization.data(withJSONObject: ["scope": scope.rawValue])
        let answer = try await requestWithGeneration(method: .deviceList, params: params)
        return (try decode([DeviceListEntry].self, answer.data), answer.generation)
    }

    /// `device.boot`: boot a simulator. When `(sessionId, cap)` is
    /// provided the daemon records ownership for that session; the
    /// GUI uses this from the .shutdown pane's Reboot button so the
    /// resurrected pane is attributed to the same tab.
    func bootDevice(
        udid: String,
        sessionId: String? = nil,
        capability: String? = nil
    ) async throws {
        _ = try await bootDeviceWithGeneration(
            udid: udid,
            sessionId: sessionId,
            capability: capability
        )
    }

    /// `device.boot`, plus the connection that recorded the ownership. A
    /// credentialed boot attributes the sim, and the owned-sim mirror has to
    /// file that against the helper it actually happened on.
    func bootDeviceWithGeneration(
        udid: String,
        sessionId: String?,
        capability: String?
    ) async throws -> Int {
        var body: [String: Any] = ["udid": udid]
        if let sessionId, let capability {
            body["sessionId"] = sessionId
            body["cap"] = capability
        }
        let params = try JSONSerialization.data(withJSONObject: body)
        return try await requestWithGeneration(method: .deviceBoot, params: params).generation
    }

    /// `device.shutdown`: stop a booted simulator. Existing daemon
    /// method; no schema change. Result is the `{ok:true}` ack,
    /// ignored here.
    func shutdownDevice(udid: String) async throws {
        let params = try JSONSerialization.data(withJSONObject: ["udid": udid])
        _ = try await request(method: .deviceShutdown, params: params)
    }

    /// `device.attach`: transfer ownership of an already-Booted
    /// `udid` to `(sessionId, capability)` and create a sim pane in
    /// one round-trip. Used by orphan re-attach (the dead previous
    /// owner is overwritten in the daemon's ownership map) and any
    /// future "attach booted sim" UX.
    func attachDevice(
        sessionId: String,
        capability: String,
        udid: String
    ) async throws -> PaneCreateResponse {
        try await attachDeviceWithGeneration(
            sessionId: sessionId,
            capability: capability,
            udid: udid
        ).response
    }

    /// `device.attach`, plus the connection that recorded the ownership, for
    /// the same reason `bootDeviceWithGeneration` carries one.
    func attachDeviceWithGeneration(
        sessionId: String,
        capability: String,
        udid: String
    ) async throws -> (response: PaneCreateResponse, generation: Int) {
        attachRevision &+= 1
        let params = try JSONSerialization.data(
            withJSONObject: [
            "udid": udid,
            "sessionId": sessionId,
            "cap": capability,
            "revision": attachRevision
            ]
            )
        let answer = try await requestWithGeneration(method: .deviceAttach, params: params)
        return (try decode(PaneCreateResponse.self, answer.data), answer.generation)
    }

    /// `device.restoreOwnership`: restore deviceterm's owned-sim claims to a
    /// helper that restarted, preserving a live session attribution where one
    /// exists. `.validatedGUI`-scoped, so no cap rides on
    /// the wire; over the `--smoke` UDS fallback the daemon refuses it with
    /// `roleViolation`, the same transport limit `restoreBatch` has.
    func restoreOwnership(
        devices: [RestoredSimOwnership]
    ) async throws -> DeviceRestoreOwnershipResult {
        let params = try JSONEncoder().encode(
            DeviceRestoreOwnershipParams(devices: devices)
        )
        let data = try await request(method: .deviceRestoreOwnership, params: params)
        return try decode(DeviceRestoreOwnershipResult.self, data)
    }

    /// `physicalDevice.list`: connected physical devices for the picker.
    /// Daemon ignores params; returns the bare-array result.
    func physicalDeviceList() async throws -> [PhysicalDeviceListEntry] {
        let params = try JSONSerialization.data(withJSONObject: [String: String]())
        let data = try await request(method: .physicalDeviceList, params: params)
        return try decode([PhysicalDeviceListEntry].self, data)
    }

    /// `physicalDevice.attach`: mount `deviceId` as a pane attributed to
    /// `sessionId`. The GUI is the trusted XPC peer, so the daemon honors the
    /// named session (its shared connection can't pick the tab via
    /// connection-auth). No `cap`: `sessionId` is attribution, not a
    /// credential.
    func attachPhysicalDevice(
        deviceId: String,
        sessionId: String
    ) async throws -> PaneCreateResponse {
        attachRevision &+= 1
        let params = try JSONSerialization.data(
            withJSONObject: [
            "deviceId": deviceId,
            "sessionId": sessionId,
            "revision": attachRevision
            ]
            )
        let data = try await request(method: .physicalDeviceAttach, params: params)
        return try decode(PaneCreateResponse.self, data)
    }

    /// `pane.closeById`: `mode` is "detach" (sim keeps running) or
    /// "shutdown" (daemon stops the sim too). Daemon honors `mode`
    /// here (unlike `session.close`).
    ///
    /// `expecting` is the `attachment` from the attach response this close is
    /// meant for. Supplying it fences the close to that admission, so one
    /// racing a re-attach can't retire the pane the re-attach handed back. Nil
    /// closes unconditionally, for callers with no admission to name.
    func closePane(
        paneId: String,
        mode: PaneCloseMode = .detach,
        expecting attachment: UInt64? = nil
    ) async throws {
        var body: [String: Any] = [
            "paneId": paneId,
            "mode": mode.rawValue
        ]
        if let attachment { body["expectedAttachment"] = attachment }
        let params = try JSONSerialization.data(withJSONObject: body)
        _ = try await request(method: .paneCloseById, params: params)
    }

    /// Subscribe to a pane's lifecycle + surface events. The returned
    /// stream finishes when the daemon ends the subscription
    /// (typically via `pane.close`). The XPC transport pairs each
    /// `surface.changed` JSON evt with its side-band surface
    /// payload before yielding, so callers see typed
    /// `PaneEvent.surfaceChanged(_, SurfaceLease?)` values directly.
    /// The UDS smoke-mode fallback can't carry the surface payload
    /// (no IOSurface XPC marshalling on UDS) so its
    /// `surfaceChanged` events always carry a `nil` lease.
    func subscribePane(paneId: String) async throws -> AsyncStream<PaneEvent> {
        var notReadyAttempts = 0
        while true {
            do {
                return try await subscribePaneOnce(paneId: paneId)
            } catch let DaemonClientError.daemon(code, _)
                where code == Self.notReadyConnectionCode
                && notReadyAttempts < Self.maxNotReadyRetries {
                // Transient provenance-not-ready: retry rather than freezing
                // the mirror (see `request`). The reconnect re-bind lands the
                // anchor; a transient validation blip recovers.
                notReadyAttempts += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func subscribePaneOnce(paneId: String) async throws -> AsyncStream<PaneEvent> {
        do {
            return try await rawSubscribePane(paneId: paneId)
        } catch let DaemonClientError.daemon(code, message)
            where code == Self.unauthorizedConnectionCode {
            // A reconnect (daemon respawn / XPC interruption) leaves the
            // daemon-side connection fresh and unauthenticated, so this
            // session-scoped subscribe -32001s even though a valid session
            // exists. Re-authenticate with a live credential and retry once,
            // exactly as `request` does for one-shot calls. Without this the
            // pane's resubscribe-on-drop loop gives up on the first
            // reconnect, freezing the mirror until something else
            // re-authenticates. A transport drop during the reauth propagates
            // (not masked as the -32001) so the resubscribe loop can retry it.
            guard try await reauthenticateAfterReconnect() else {
                throw DaemonClientError.daemon(code: code, message: message)
            }
            return try await rawSubscribePane(paneId: paneId)
        }
    }

    /// The handshake is bounded like a one-shot request. Only the handshake
    /// is: the stream it returns is long-lived by design and carries no
    /// deadline.
    private func rawSubscribePane(paneId: String) async throws -> AsyncStream<PaneEvent> {
        let params = try JSONSerialization.data(withJSONObject: ["paneId": paneId])
        return try await bounded(.paneSubscribe) { [self] in
            try await rawSubscribePaneOnTransport(paneId: paneId, params: params)
        }
    }

    private func rawSubscribePaneOnTransport(
        paneId: String,
        params: Data
    ) async throws -> AsyncStream<PaneEvent> {
        if let injectedSubscribeTransport {
            return try await injectedSubscribeTransport.subscribePane(paneId: paneId)
        }
        switch transport {
        case let .xpc(connection):
            let (_, stream) = try await connection.subscribe(
                method: RPCMethod.paneSubscribe.rawValue,
                params: params,
                paneId: paneId
            )
            return stream

        case let .uds(connection):
            let (_, raw) = try await connection.subscribe(
                method: RPCMethod.paneSubscribe.rawValue,
                params: params
            )
            return AsyncStream { continuation in
                let task = Task {
                    for await (method, data) in raw {
                        switch PaneEventName(rawValue: method) {
                        case .surfaceChanged:
                            if let event = try? JSONDecoder().decode(
                                SurfaceChangedEvent.self,
                                from: data
                            ) {
                                continuation.yield(.surfaceChanged(event, nil))
                            }

                        case .stateChanged:
                            if let event = try? JSONDecoder().decode(
                                StateChangedEvent.self,
                                from: data
                            ) {
                                continuation.yield(.stateChanged(event))
                            }

                        case .orientationChanged:
                            if let event = try? JSONDecoder().decode(
                                OrientationChangedEvent.self,
                                from: data
                            ) {
                                continuation.yield(.orientationChanged(event))
                            }

                        case nil:
                            break
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Discrete tap at normalized (0..1) coords.
    func paneInputTap(paneId: String, x: Double, y: Double) async throws {
        try await paneInput(.paneInputTap, body: TapParams(paneId: paneId, x: x, y: y))
    }

    /// Live single-finger touch update used by the GUI drag path.
    func paneInputTouch(
        paneId: String,
        x: Double,
        y: Double,
        phase: TouchPhase
    ) async throws {
        try await paneInput(
            .paneInputTouch,
            body: TouchParams(paneId: paneId, x: x, y: y, phase: phase.rawValue)
        )
    }

    /// Swipe path. Coords normalized 0..1; duration in milliseconds.
    func paneInputSwipe(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int,
        holdMs: Int,
        startHoldMs: Int
    ) async throws {
        try await paneInput(
            .paneInputSwipe,
            body: SwipeParams(
                paneId: paneId,
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                durationMs: durationMs,
                holdMs: holdMs,
                startHoldMs: startHoldMs
            )
        )
    }

    func paneInputEdgeSwipe(
        paneId: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        edge: Int,
        durationMs: Int,
        holdMs: Int
    ) async throws {
        try await paneInput(
            .paneInputEdgeSwipe,
            body: EdgeSwipeParams(
                paneId: paneId,
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                edge: edge,
                durationMs: durationMs,
                holdMs: holdMs
            )
        )
    }

    /// Per-event edge-tagged live touch: the App Switcher follows the
    /// cursor on a bottom-edge mouse drag. Coords normalized; `edge` is
    /// the raw `IndigoHIDEdge` value.
    func paneInputEdgeTouch(
        paneId: String,
        x: Double,
        y: Double,
        phase: TouchPhase,
        edge: Int
    ) async throws {
        try await paneInput(
            .paneInputEdgeTouch,
            body: EdgeTouchParams(paneId: paneId, x: x, y: y, phase: phase.rawValue, edge: edge)
        )
    }

    /// Long-press at normalized coords for `durationMs` milliseconds.
    func paneInputLongPress(
        paneId: String,
        x: Double,
        y: Double,
        durationMs: Int
    ) async throws {
        try await paneInput(
            .paneInputLongPress,
            body: LongPressParams(paneId: paneId, x: x, y: y, durationMs: durationMs)
        )
    }

    /// `keyCode` is a macOS HIToolbox virtual-key value
    /// (i.e. `NSEvent.keyCode`, kVK_*), the daemon owns the
    /// kVK→USB-HID translation (`KeyboardInputMap.kVKToHIDUsage`),
    /// so callers pass raw `NSEvent.keyCode`
    /// through. `down=true` is keydown, `down=false` is keyup.
    func paneInputKey(paneId: String, keyCode: UInt32, down: Bool) async throws {
        try await paneInput(
            .paneInputKey,
            body: KeyParams(paneId: paneId, keyCode: keyCode, down: down)
        )
    }

    /// Hardware button press: home / lock / side / applePay / siri.
    func paneInputButton(paneId: String, button: HardwareButton) async throws {
        try await paneInput(
            .paneInputButton,
            body: ButtonParams(paneId: paneId, button: button.rawValue)
        )
    }

    /// Two-finger pinch path. All coords normalized 0..1.
    func paneInputPinch(
        paneId: String,
        fromF1X: Double,
        fromF1Y: Double,
        fromF2X: Double,
        fromF2Y: Double,
        toF1X: Double,
        toF1Y: Double,
        toF2X: Double,
        toF2Y: Double,
        durationMs: Int
    ) async throws {
        try await paneInput(
            .paneInputPinch,
            body: PinchParams(
                paneId: paneId,
                fromF1X: fromF1X,
                fromF1Y: fromF1Y,
                fromF2X: fromF2X,
                fromF2Y: fromF2Y,
                toF1X: toF1X,
                toF1Y: toF1Y,
                toF2X: toF2X,
                toF2Y: toF2Y,
                durationMs: durationMs
            )
        )
    }

    /// Live two-finger touch frame (Option-drag pinch/rotate). Coords
    /// normalized (may be off-[0,1] for a mirrored finger); the two
    /// contacts go on the wire as `points` with stable ids 0 and 1.
    func paneInputMultitouch(
        paneId: String,
        phase: TouchPhase,
        finger1: CGPoint,
        finger2: CGPoint
    ) async throws {
        try await paneInput(
            .paneInputMultitouch,
            body: MultitouchParams(
                paneId: paneId,
                phase: phase.rawValue,
                points: [
                    MultitouchPoint(id: 0, x: Double(finger1.x), y: Double(finger1.y)),
                    MultitouchPoint(id: 1, x: Double(finger2.x), y: Double(finger2.y))
                ]
            )
        )
    }

    /// ASCII text input: daemon translates each char to HID usages.
    func paneInputText(paneId: String, text: String) async throws {
        try await paneInput(.paneInputText, body: TextParams(paneId: paneId, text: text))
    }

    /// Set device orientation.
    func paneInputRotate(paneId: String, orientation: Orientation) async throws {
        try await paneInput(
            .paneInputRotate,
            body: RotateParams(paneId: paneId, orientation: orientation.rawValue)
        )
    }

    /// Drive the watchOS Digital Crown. Delta is in the bridge's raw
    /// crown unit (~1 unit per detent); positive = forward/down.
    /// `durationMs == 0` sends one-shot; positive sub-steps at ~60Hz.
    func paneInputCrown(
        paneId: String,
        delta: Double,
        durationMs: Int
    ) async throws {
        try await paneInput(
            .paneInputCrown,
            body: CrownParams(paneId: paneId, delta: delta, velocity: nil, durationMs: durationMs)
        )
    }

    private func paneInput(_ method: RPCMethod, body: some Encodable) async throws {
        let params = try JSONEncoder().encode(body)
        _ = try await request(method: method, params: params)
    }

    /// `pane.ax.point`: return the AX element at normalized `(x, y)`,
    /// summarized for inline chrome display. The wire shape is an
    /// opaque JSON dict (CLI's `ax point` prints it verbatim); the
    /// chrome only needs "what is this thing?" so we extract role +
    /// label + identifier and join them with `·`. Returns nil when the
    /// daemon's response carries no element (cursor over chrome / off-
    /// screen / between elements).
    func paneAxPoint(paneId: String, x: Double, y: Double) async throws -> String? {
        let params = try JSONEncoder().encode(AXPointParams(paneId: paneId, x: x, y: y))
        let data = try await request(method: .paneAXPoint, params: params)
        return AxElementSummary.parse(data)
    }

    /// `pane.location.set`: apply a simulated GPS position. A thrown
    /// request does not establish the device's final location, since a
    /// transport failure can occur after the daemon applied the command.
    /// Use `pane.location.state` to read the daemon's recorded claim.
    func paneLocationSet(paneId: String, location: SimulatedLocation) async throws {
        let params = try JSONEncoder().encode(
            PaneLocationSetParams(paneId: paneId, location: location)
        )
        _ = try await request(method: .paneLocationSet, params: params)
    }

    /// `pane.location.state`: the location deviceterm last applied plus
    /// the device's scenario list. See `PaneLocationStateResult`. The
    /// location is a claim about the device, not a reading from it.
    func paneLocationState(paneId: String) async throws -> PaneLocationStateResult {
        let params = try JSONEncoder().encode(PaneLocationStateParams(paneId: paneId))
        let data = try await request(method: .paneLocationState, params: params)
        return try JSONDecoder().decode(PaneLocationStateResult.self, from: data)
    }

    private func request(method: RPCMethod, params: Data?) async throws -> Data {
        try await requestWithGeneration(method: method, params: params).data
    }

    /// `request`, carrying the connection that answered out with the data.
    /// For a caller that has to say which helper a state change landed on.
    private func requestWithGeneration(
        method: RPCMethod,
        params: Data?
    ) async throws -> (data: Data, generation: Int) {
        var notReadyAttempts = 0
        while true {
            // Check cancellation at the TOP of every iteration, before sending.
            // The `try` on `Task.sleep` below only catches cancellation that
            // arrives DURING the backoff; cancellation arriving after the sleep
            // returns but before the next `requestOnce` would otherwise send
            // another call (e.g. a grant whose tab tore down between attempts).
            try Task.checkCancellation()
            do {
                return try await requestOnce(method: method, params: params)
            } catch let DaemonClientError.daemon(code, _)
                where code == Self.notReadyConnectionCode
                && notReadyAttempts < Self.maxNotReadyRetries {
                // Transient provenance-not-ready: retry briefly (validation
                // recovers, or the terminal anchor lands after a reconnect
                // re-bind). Bounded so a genuinely stuck state still surfaces.
                // `try` (not `try?`): if the caller's task was cancelled,
                // `Task.sleep` throws `CancellationError`, which propagates and
                // ends the loop rather than silently sending the call again.
                notReadyAttempts += 1
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func requestOnce(
        method: RPCMethod,
        params: Data?
    ) async throws -> (data: Data, generation: Int) {
        do {
            return try await rawRequest(method: method, params: params)
        } catch let DaemonClientError.daemon(code, message)
            where code == Self.unauthorizedConnectionCode
            && method != .sessionAuthenticate
            && method != .sessionSetPrivateBatch
            && method != .sessionPrivacySnapshot
            && method != .sessionRestoreBatch
            && method != .sessionSetDisplayTitle
            && method != .orchestratorGrant {
            // The connection was re-established (daemon respawn / XPC
            // interruption) so the daemon-side `RPCConnection` is fresh
            // and unauthenticated: every session-scoped call now -32001s
            // even though a valid session exists. Re-authenticate with a live
            // credential and retry the call once. Without this, the first
            // session-scoped call after any reconnect (typically a
            // deliberate, infrequent device mirror) fails until something
            // happens to call `createSession` again. Re-authenticate once so
            // the session-scoped call survives the connection replacement. No
            // live session (none yet, or all closed) or a walk that exhausts
            // every credential the daemon rejects both fall through to the
            // original error; a transport drop mid-reauth propagates so the
            // caller can classify it.
            //
            // `session.setPrivateBatch` is excluded: it is `.validatedGUI`
            // (audit-token authority, no session auth to lose on reconnect),
            // so its `-32001` is only ever "unknown session in the batch":
            // never a reconnect. A transparent retry here would physically
            // resend the SAME encoded `revision`, violating the
            // fresh-revision-per-send ordering invariant. Let the `-32001`
            // propagate so the Router allocates a fresh revision for any
            // retry.
            //
            // `orchestrator.grant` is excluded for the same reason: it is
            // `.validatedGUI` and carries a monotonic `revision`, so a silent
            // resend would replay a stale key. It stamps a fresh revision on
            // each explicit send and is reissued naturally on reconnect once the
            // terminal rebinds, so no transparent retry is needed.
            //
            // `session.setDisplayTitle` is excluded because its `-32001` is
            // likewise only ever "unknown session": the session died, so the
            // publisher must see that and abandon that value rather than
            // reauthenticate as some other session and resend. It keeps
            // publishing because the tab may re-seat onto a live session.
            guard try await reauthenticateAfterReconnect() else {
                throw DaemonClientError.daemon(code: code, message: message)
            }
            return try await rawRequest(method: method, params: params)
        }
    }

    private func rawRequest(
        method: RPCMethod,
        params: Data?
    ) async throws -> (data: Data, generation: Int) {
        // The calls that mint daemon state are bounded by their own caller
        // instead, because bounding them HERE would cancel the transport and
        // discard the reply naming what was minted. `createSession` wraps
        // itself; the attaches are wrapped by the Router, which is the layer
        // that can tell whether a late pane is still wanted. See
        // `DaemonClientError.timedOut`.
        guard !Self.selfReconcilingMethods.contains(method) else {
            // These skip `bounded`, so they'd also skip the accounting it
            // does. An attach is as much proof the helper is alive as any
            // other call, whether it succeeded or was refused, and a streak
            // neither cleared would outlive the condition that started it.
            do {
                let answer = try await transportRequest(method: method, params: params)
                noteHelperAnswered()
                return answer
            } catch {
                noteHelperFailure(error)
                throw error
            }
        }
        return try await bounded(method) { [self] in
            try await transportRequest(method: method, params: params)
        }
    }

    /// Record that the helper answered, ending any streak in progress. Only
    /// *consecutive* unanswered calls say it has stopped answering, so one
    /// reply is enough to clear the count however long the streak was.
    private func noteHelperAnswered() {
        consecutiveTimeouts = 0
    }

    /// Record a call that reached its deadline unanswered, and report once the
    /// streak has reached the threshold.
    ///
    /// Every expiry at or past the threshold reports, not just the one that
    /// crosses it. A helper that never answers again produces nothing but
    /// expiries, so reporting only the crossing would leave the observer with
    /// exactly one signal for the whole condition: whoever it told could
    /// choose to wait, and then never hear about it again. Suppressing the
    /// repeats is the observer's call, because only it knows whether it is
    /// already showing something or was recently told to leave it alone.
    private func noteHelperSilent() {
        consecutiveTimeouts += 1
        guard consecutiveTimeouts >= Self.unresponsiveTimeoutThreshold else { return }
        onUnresponsive?(connectionGeneration)
    }

    /// Fold a failed call into the streak.
    ///
    /// `bounded` and `createSession` both classify through here so the call
    /// that bounds itself can't drift from the ones `bounded` wraps. The
    /// Router's attach deadline does not: that bound is raised in the Router
    /// and never reaches this client, so an attach that expires doesn't
    /// lengthen the streak. Its reply still clears it when one arrives, since
    /// that comes back through `rawRequest`.
    private func noteHelperFailure(_ error: any Error) {
        guard let error = error as? DaemonClientError else {
            // A cancellation, or an encoding fault on the way out: neither
            // says anything about whether the helper is answering.
            return
        }
        switch error {
        case .timedOut:
            noteHelperSilent()

        // A reply came back, even though it was a refusal or something this
        // client couldn't decode. The streak counts the absence of replies, so
        // any of these ends it; treating a prompt rejection as silence would
        // diagnose a helper that is plainly answering.
        case .daemon, .decode, .versionMismatch:
            noteHelperAnswered()

        // Neither silence nor an answer. A transport loss says the connection
        // went away, which recovers on the next send. The shutdown acks are
        // bounded by their own caller and never reach here, so they have no
        // streak to affect.
        case .transport, .shutdownNotAcknowledged, .shutdownTimedOut:
            break
        }
    }

    /// One transport call, carrying the connection that answered it out
    /// alongside the data.
    ///
    /// The XPC path captures the generation with the send rather than sampling
    /// it afterward, and a successful response implies no invalidation during
    /// the request, so the send-time generation IS the one that answered. A
    /// caller that has to attribute an answer to a particular helper needs
    /// that; sampling after the await can name a replacement instead. The
    /// injected and UDS paths have no live generation to race, so they report
    /// the current value.
    private func transportRequest(
        method: RPCMethod,
        params: Data?
    ) async throws -> (data: Data, generation: Int) {
        if let injectedRequestTransport {
            let data = try await injectedRequestTransport.request(
                method: method.rawValue,
                params: params
            )
            return (data, await xpcConnection.currentGeneration)
        }
        switch transport {
        case let .xpc(connection):
            return try await connection.requestReturningGeneration(
                method: method.rawValue,
                params: params
            )

        case let .uds(connection):
            let data = try await connection.request(method: method.rawValue, params: params)
            return (data, await xpcConnection.currentGeneration)
        }
    }

    /// Run one transport call under a deadline, so a daemon that accepts a
    /// request and then stops answering can't park a caller forever.
    ///
    /// Every wrapped call is a *transport* call, not a whole retry loop: the
    /// `-32002` retry in `request` and the reauth retry in `requestOnce` each
    /// bound their attempts individually, which is what keeps a single bound
    /// meaningful whether or not a call was retried.
    ///
    /// The loser of the race is cancelled and awaited at scope exit, so this
    /// only terminates because both transports honor cancellation on a parked
    /// continuation (`XPCDaemonConnection.requestReturningGeneration`,
    /// `UDSDaemonConnection.request`, and both subscribe handshakes). A
    /// transport that ignored cancellation would hang here rather than time
    /// out, which is why test transports model a silent *peer*.
    ///
    /// Abandoning the wait does NOT cancel the daemon's handler, so a call
    /// that mutates daemon state leaves an unknown outcome behind; see
    /// `DaemonClientError.timedOut` for what that costs and what recovers it.
    ///
    /// `operation` stays `@MainActor` so the raced call runs in the same
    /// isolation it would without the race, reaching `transport` and the
    /// injected test seams directly.
    private func bounded<T: Sendable>(
        _ method: RPCMethod,
        _ operation: @escaping @Sendable @MainActor () async throws -> T
    ) async throws -> T {
        let deadline = Self.slowMethods.contains(method)
            ? slowRequestDeadlineNanos
            : requestDeadlineNanos
        do {
            let value = try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(nanoseconds: deadline)
                    throw DaemonClientError.timedOut(method: method.rawValue)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw DaemonClientError.timedOut(method: method.rawValue)
                }
                return first
            }
            noteHelperAnswered()
            return value
        } catch {
            noteHelperFailure(error)
            throw error
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw DaemonClientError.decode("\(T.self): \(error)")
        }
    }

    /// `daemon.ping`: on wire-version mismatch, the daemon is from
    /// an older / newer install. Surface a typed error; the GUI's
    /// outer layer (App's launch path) decides how to remediate
    /// (it bails with a typed alert).
    func versionHandshake() async throws {
        // Capture the generation ATOMICALLY with the ping (see
        // `pingWithGeneration`), so remediation fences the shutdown to the exact
        // daemon instance that answered: a replacement connecting can't be
        // sampled as the answering one.
        let (pong, generation) = try await pingWithGeneration()
        guard pong.version == DaemonProtocolInfo.wireVersion else {
            // Surface here (once) with that generation, then rethrow so the
            // caller aborts the launch/reconnect without a second alert.
            let mismatch = DaemonClientError.versionMismatch(
                client: DaemonProtocolInfo.wireVersion,
                daemon: pong.version
            )
            await surfaceVersionMismatch(mismatch, generation: generation)
            throw mismatch
        }
    }

    /// Ping the daemon and return the connection generation the ping was
    /// answered on, captured ATOMICALLY with the request, not sampled
    /// afterward, where a replacement connecting between the two `await`s could
    /// be mistaken for the answering instance. Only the production XPC path has
    /// that reconnect race; injected (tests) and UDS (smoke) have no live
    /// generation to race, so they sample the current value.
    private func pingWithGeneration() async throws -> (DaemonPingResponse, Int) {
        if injectedRequestTransport == nil, case let .xpc(connection) = transport {
            // Bounded here rather than inherited from `request`: this branch
            // reaches the transport directly, so an unanswered handshake ping
            // would otherwise park launch (and every reconnect) forever.
            let (data, generation) = try await bounded(.daemonPing) {
                try await connection.requestReturningGeneration(
                    method: RPCMethod.daemonPing.rawValue,
                    params: nil
                )
            }
            return (try decode(DaemonPingResponse.self, data), generation)
        }
        let pong = try await ping()
        return (pong, await xpcConnection.currentGeneration)
    }

    /// Test seam: the current XPC connection generation.
    func currentXPCGeneration() async -> Int { await xpcConnection.currentGeneration }

    /// Test seam: the underlying XPC connection, so a controlled-peer test can
    /// install a replying peer and bump the generation mid-handshake.
    func xpcConnectionForTesting() -> XPCDaemonConnection { xpcConnection }

    // MARK: - AppCommandControlling

    /// Deliberately NOT deadline-bounded, unlike every other call here.
    ///
    /// The daemon keeps one `app.commands` subscriber and a new subscribe
    /// evicts the incumbent, XPC dispatch is non-FIFO, and no wire method
    /// retires a raw subscription. So a handshake this side abandoned could
    /// still be handled after the retry that replaced it, evicting the live
    /// subscriber in favor of an envelope this client already dropped. The
    /// eviction finishes the live stream and the drain loop resubscribes, so
    /// it converges, but it converges through a window where CLI verbs from
    /// other tabs go unanswered.
    ///
    /// Nothing *waits* on this handshake: no launch step or route dispatch
    /// blocks on it, and a parked one is released either by the daemon
    /// answering late or by the connection dropping (which fails it and sends
    /// the drain loop around). CLI-originated routes do arrive over the
    /// resulting subscription, so the cost of parking is the same delivery gap
    /// the eviction window above would cause, without the risk of unseating a
    /// working subscriber.
    func subscribeAppCommands() async throws
    -> (initial: Data, events: AsyncStream<(String, Data)>) {
        switch transport {
        case let .xpc(connection):
            return try await connection.subscribeRaw(
                method: RPCMethod.appCommands.rawValue,
                params: nil
            )

        case let .uds(connection):
            return try await connection.subscribe(
                method: RPCMethod.appCommands.rawValue,
                params: nil
            )
        }
    }

    func sendAppCommandResult(_ result: AppCommandResult) async throws {
        let params = try JSONEncoder().encode(result)
        _ = try await request(method: .appCommandResult, params: params)
    }
}

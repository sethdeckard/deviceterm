// SPDX-License-Identifier: GPL-3.0-or-later
//
// XPCDaemonConnection: the GUI's XPC peer onto the launchd-vended
// daemon mach service.
//
// The daemon is registered via `SMAppService.agent` (see
// `DaemonRegistration`), launchd holds the listener, and the GUI
// connects via `xpc_connection_create_mach_service`. Reconnect on
// invalidation is a single call: launchd demand-launches the
// daemon on the next send. (`UDSDaemonConnection` is the
// `--smoke`-only fallback.)
//
// **Wire shape (request).** The connection ships `RPCEnvelope` JSON
// bytes inside an `xpc_dictionary` with a `type` discriminator:
//
//   { type: "rpc", data: <RPCEnvelope JSON bytes> }
//
// **Wire shape (replies + events).** The daemon sends the same
// envelope shape back; this connection's event handler decodes the
// envelope and either resumes the matching request continuation
// or yields to the matching subscription stream.
//
// **Wire shape (surface payload).** Surface frames ride on a second
// dictionary type that pairs with a JSON `surface.changed` evt. It
// always carries the subscription token, plus the device lease overlay
// (`leased`/`leaseEpoch`):
//
//   { type: "surface", paneId: <string>, sequence: <uint64>,
//     subscriptionToken: <uuid>, leased: <bool>, leaseEpoch: <uint64>,
//     surface: <xpc_object_t> }
//
// The connection holds an actor-isolated correlation table indexed by
// `(paneId, sequence, token)`, so two subscriptions on one pane never
// cross-deliver. Each side of the pair fills its half when it arrives. The
// side-band builds the `SurfaceLease` immediately (leased ⇒ use-count bumped
// + registered with the release accountant); once both halves are present
// the connection yields a single `PaneEvent.surfaceChanged(_, SurfaceLease?)`
// to the owning subscription only. A slot held only by the surface (JSON dropped/late)
// ages out after 250ms: its lease releases by ARC; a slot held only by
// the JSON yields `(_, nil)` after the same timeout. Reconnect clears the
// correlation table so a frame from the old connection can never pair with
// one from the new.

import DaemonProtocol
import Foundation
import IOSurface
import os
@preconcurrency import XPC
#if canImport(Darwin)
import Darwin
#endif

/// The GUI half of the connection timeline, under the app's own subsystem.
///
/// Read these events with the daemon's `com.deviceterm.daemon` logs, correlated
/// by timestamp. There is no shared cross-process connection id: the two ends
/// number connections independently, and introducing a shared one would put a
/// correlation token on the wire for a diagnostic.
private let connectionLog = Logger(subsystem: "com.deviceterm", category: "xpc")

/// A short, log-safe name for an XPC error object.
///
/// Duplicated in the daemon rather than shared: the two live in different
/// modules, and the only one they have in common (`DaemonProtocol`) is
/// Foundation-only, so hoisting this would mean linking XPC into it for a
/// ten-line classifier.
private func describeXPCError(_ event: xpc_object_t) -> String {
    if event === XPC_ERROR_CONNECTION_INTERRUPTED { return "connection-interrupted" }
    if event === XPC_ERROR_CONNECTION_INVALID { return "connection-invalid" }
    if event === XPC_ERROR_TERMINATION_IMMINENT { return "termination-imminent" }
    guard let raw = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION) else {
        return "unknown-xpc-error"
    }
    return String(cString: raw)
}

/// XPC dictionary keys + discriminators on the GUI side. Mirror
/// `XPCTransportKey` in the daemon so the two ends agree without
/// re-typing string literals, but the GUI module can't import the
/// daemon, so the constants are duplicated here.
enum XPCWireKey {
    static let type = "type"
    static let data = "data"
    static let paneId = "paneId"
    static let sequence = "sequence"
    static let surface = "surface"

    static let rpcValue = "rpc"
    static let surfaceValue = "surface"

    // Correlation token (every XPC pane subscription, sim + device) plus the
    // device-only lease overlay (leased/leaseEpoch).
    static let subscriptionToken = "subscriptionToken"
    static let leased = "leased"
    static let leaseEpoch = "leaseEpoch"
}

/// Sendable box for an `xpc_object_t` so it can ride the ordered ingress
/// `AsyncStream`. XPC objects are reference-counted and thread-safe to
/// pass across queues, which is why the unchecked conformance holds.
struct XPCEventBox: @unchecked Sendable {
    let event: xpc_object_t
}

actor XPCDaemonConnection: DaemonRequestTransport {
    /// Correlation key for one delivered frame. The subscription token
    /// disambiguates two subscriptions on one pane that carry the same
    /// `(paneId, sequence)`, so their frames never cross-deliver.
    private struct PairKey: Hashable {
        let paneId: String
        let sequence: UInt64
        let token: UUID
    }

    /// One half of a surface-pair slot. The `lease` is built when the
    /// side-band lands; for a leased device frame that means its use-count
    /// bump + accountant `acquire` happen immediately (even before the JSON
    /// half or the subscribe response), while an unleased frame takes
    /// neither. The JSON `event` half arrives on the subscription's stream.
    /// A dropped slot releases the lease by ARC.
    private struct PendingSurfacePair {
        var event: SurfaceChangedEvent?
        var lease: SurfaceLease?
        var insertedAt: Date
    }

    /// Consumer-pulled coalescing state for one pane subscription. The VM
    /// stream is an `AsyncStream(unfolding:)` that pulls from here, so while
    /// the @MainActor consumer is stalled surfaces are held **latest-only**
    /// (older un-pulled surfaces coalesce away and release their leases by
    /// ARC), while control events queue **losslessly** in FIFO order: the
    /// `lifecycleQueue` grows without a configured bound (it drains as the
    /// consumer pulls; there is no cap). `waiter`
    /// parks a pull until an event arrives; `finished` ends the stream.
    private final class PaneSubscriptionState {
        let paneId: String
        var lifecycleQueue: [PaneEvent] = []
        var latestSurface: PaneEvent?
        var waiter: CheckedContinuation<PaneEvent?, Never>?
        var finished = false

        init(paneId: String) { self.paneId = paneId }
    }

    /// A live subscription the GUI is consuming. Pane subscriptions pull
    /// coalescing state (surfaces latest-only, control events lossless);
    /// raw subscriptions (`app.commands`) keep a plain push continuation
    /// and don't participate in surface correlation.
    private enum SubscriptionRecord {
        case pane(PaneSubscriptionState)
        case raw(continuation: AsyncStream<(String, Data)>.Continuation)
    }

    /// What the transport will carry once a definite wire-version mismatch is
    /// being handled.
    ///
    /// In both non-normal modes every entry point except the bootstrap methods
    /// refuses immediately, so no ordinary request or subscription can restore
    /// state against a replacement daemon. This is the transport-level fence the
    /// reconnect-callback guard alone can't be: `request`/`subscribe`/
    /// `subscribeRaw` all demand-`connect()` before the callback could refuse
    /// them.
    ///
    /// `.recovering` is not a weaker `.incompatible`. It admits the two
    /// bootstrap methods a startup recovery needs, and it admits a
    /// demand-connect for `daemon.ping` alone, because launching the replacement
    /// is the whole point of that ping. `daemon.shutdown` never demand-connects
    /// in either mode: the one send it is allowed must reach the peer that
    /// answered the mismatched ping, and connecting would demand-launch (and
    /// then stop) whatever replaced it.
    ///
    /// `.incompatible` is terminal and absorbing. `leaveRecovery` cannot revive
    /// it, so a recovery that has already given up can't be walked back by a
    /// later caller.
    private enum Mode {
        case normal
        case recovering
        case incompatible
    }

    /// Whether a method is allowed through, and whether it may demand-connect.
    ///
    /// The two are separate because they diverge in `.recovering`: `daemon.ping`
    /// needs the connect and `daemon.shutdown` must not have it. A mode-level
    /// "may connect" flag would have to pick one and would be wrong for the
    /// other.
    private struct Admission {
        let connectIfNeeded: Bool
    }

    private let machServiceName: String
    private var connection: xpc_connection_t?
    private var nextId: UInt32 = 1
    private var pendingRequests: [UInt32: CheckedContinuation<Data, Error>] = [:]
    private var subscriptions: [UInt32: SubscriptionRecord] = [:]
    private var pendingSurfacePairs: [PairKey: PendingSurfacePair] = [:]
    /// `pane.subscribe` request id → its correlation token, installed from
    /// the subscribe ack (synchronously, before the continuation resumes,
    /// so a following JSON `surface.changed` on that stream can find it).
    private var subscriptionTokens: [UInt32: UUID] = [:]
    /// Reverse of `subscriptionTokens`, so a side-band (which carries the
    /// token, not the request id) routes to the right subscription.
    private var envelopeForToken: [UUID: UInt32] = [:]
    /// Background sweeper task: drops aged-out half-pairs.
    private var sweeperTask: Task<Void, Never>?
    /// Ordered inbound pump: the libxpc handler yields every event into a
    /// serial stream that a single task drains, so the subscribe ack is
    /// processed before the JSON `surface.changed` that follows it (Swift
    /// gives no ordering to a Task-per-callback). Recreated per connection.
    private var inbound: AsyncStream<XPCEventBox>.Continuation?
    private var inboundPump: Task<Void, Never>?
    /// GUI half of the lease loop: tracks held generations and emits
    /// cumulative `pane.surfaceRelease` watermarks. Recreated per connection.
    private var accountant: SurfaceReleaseAccountant?
    /// Fired when `connect()` establishes a NEW peer following a prior one,
    /// i.e. an actual transport reconnection after an invalidation, NOT the
    /// first connect. Driven directly off the transport (not off a `-32001`
    /// reauth), so it fires even when the only traffic that reconnected is the
    /// always-running `.validatedGUI` `app.commands` subscription, otherwise a
    /// terminal-only tab (which makes no session-scoped calls, so never sees a
    /// `-32001`) would never re-bind its anchor after a daemon restart.
    private var onReconnect: (@Sendable (Int) -> Void)?
    private var connectionGeneration = 0
    private var mode: Mode = .normal

    /// The current connection generation, bumped on every (re)connect. The
    /// mismatch remediation captures this alongside the mismatched ping so it
    /// can fence the shutdown to the SAME daemon instance (a demand-reconnect
    /// onto a replacement bumps it).
    var currentGeneration: Int { connectionGeneration }

    /// Test seam: number of in-flight requests still awaiting a reply. Lets a
    /// test assert pending-state cleanup after a cancellation.
    var pendingRequestCountForTesting: Int { pendingRequests.count }

    init(machServiceName: String) {
        self.machServiceName = machServiceName
    }

    /// The handler receives the generation of the connection just installed,
    /// captured here rather than read back later. A caller that reads it
    /// afterwards gets whatever is current at read time, which is a different
    /// value from the one it is reacting to as soon as anything reconnects in
    /// between.
    func setReconnectHandler(_ handler: @escaping @Sendable (Int) -> Void) {
        onReconnect = handler
    }

    /// Terminally quiesce the transport, ALWAYS, regardless of generation:
    /// refuse new traffic (only the in-progress bootstrap `daemon.shutdown`
    /// stays permitted), fail in-flight requests, finish open subscriptions, and
    /// drop one-way notifications (`sendNotification`). So even a REPLACEMENT
    /// connection (whose generation has moved on) can't keep running
    /// subscriptions/RPCs that will never complete a reconnect handshake once
    /// remediation has latched.
    ///
    /// Returns whether the current connection is STILL the pinned
    /// `expectedGeneration`, i.e. whether the caller may send the bootstrap
    /// shutdown to it. A replacement is quiesced too, but must NOT receive
    /// shutdown (it's a different, possibly-updated daemon). The shutdown, when
    /// permitted, is sent AFTER this as a fresh request against the SAME peer.
    /// Pass nil for `expectedGeneration` to go terminal with nothing pinned,
    /// which answers that no bootstrap shutdown may be sent. That is the shape a
    /// recovery uses when it gives up: no further shutdown is authorized once
    /// recovery is terminal.
    @discardableResult
    func markIncompatible(expectedGeneration: Int?) -> Bool {
        let pinned = expectedGeneration.map { connectionGeneration == $0 } ?? false
        mode = .incompatible
        quiesce()
        return pinned
    }

    /// Quiesce and pin for a startup recovery, which may still reach the peer
    /// with the two bootstrap methods.
    ///
    /// Same one-actor-turn guarantee as `markIncompatible`: the generation
    /// check, the mode change, and the quiesce cannot be interleaved, so a
    /// replacement can't be installed between deciding and fencing.
    ///
    /// The quiesce is a no-op in practice here, because recovery is entered only
    /// from the startup handshake, before any window, session, or subscription
    /// exists. It runs anyway rather than being skipped on that reasoning: the
    /// reasoning is about the caller, and this type shouldn't depend on it.
    @discardableResult
    func enterRecovery(expectedGeneration: Int) -> Bool {
        let pinned = connectionGeneration == expectedGeneration
        mode = .recovering
        quiesce()
        return pinned
    }

    /// Return to full service after a recovery re-established a compatible
    /// helper. A no-op from `.incompatible`, which is absorbing: nothing revives
    /// a transport that already surrendered.
    func leaveRecovery() {
        guard case .recovering = mode else { return }
        mode = .normal
    }

    /// Fail every in-flight request and finish every subscription, so nothing
    /// keeps running over a connection that is about to be replaced or
    /// abandoned.
    private func quiesce() {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(
                throwing: DaemonClientError.transport("daemon incompatible; connection terminal")
            )
        }
        let subs = subscriptions
        subscriptions.removeAll()
        for (_, record) in subs { finishSubscription(record) }
    }

    /// Stop the helper process on the other end of this connection.
    ///
    /// The pid comes from `xpc_connection_get_pid` on the live peer, never
    /// from an RPC reply: the case this exists for is a helper that has
    /// stopped answering, so there is no reply to read, and a pid a caller
    /// supplied names whatever it chose to. Reading the peer and signalling it
    /// happen in this one actor turn with nothing awaited in between, so this
    /// connection can't be swapped underneath the lookup.
    ///
    /// What that does not buy is the pid itself. The process is free to exit
    /// between the two calls, and the kernel is free to reuse its number.
    /// `ESRCH` catches the ordinary form of that; a number reused inside the
    /// same instant is not something a pid-based kill can rule out.
    ///
    /// `expectedGeneration` fences the kill to one connection. The
    /// unresponsive prompt captures the generation it was raised against, so
    /// a newer connection installed while the prompt sat on screen returns
    /// `.alreadyRestarted` rather than the current peer being signalled in
    /// its place. Pass nil to signal the connected peer with no fence, which
    /// is what asking for a restart outright means.
    ///
    /// SIGKILL, not SIGTERM: a helper blocked inside a synchronous
    /// CoreSimulator call, or stopped outright, runs no handler, and a stopped
    /// process never even dequeues SIGTERM. SIGKILL terminates both without
    /// needing the process to run anything.
    func terminateCurrentPeer(expectedGeneration: Int?) -> HelperTerminationOutcome {
        if let expectedGeneration, connectionGeneration != expectedGeneration {
            return .alreadyRestarted
        }
        return signalConnectedPeer()
    }

    /// Stop the connected peer only when it is `expectedPid`.
    ///
    /// The pid is the right fence for a wire-version recovery, where the
    /// generation is not. Recovery re-pings after asking the helper to stop, so
    /// by the time it decides to signal, the connection may legitimately have
    /// been replaced; what it needs to know is whether the process it asked to
    /// go away is the one still answering. Signalling on generation alone would
    /// kill a freshly launched replacement, and launchd would start another
    /// exactly like it (`KeepAlive`/`SuccessfulExit false`), so the loop would
    /// never converge.
    func terminatePeer(expectedPid: pid_t) -> HelperTerminationOutcome {
        guard let peer = connection else { return .alreadyGone }
        guard xpc_connection_get_pid(peer) == expectedPid else { return .alreadyRestarted }
        return signalConnectedPeer()
    }

    /// SIGKILL whatever process is on the far end of the live connection,
    /// classifying what happened. Callers own the fence that decides whether
    /// this peer is the right one to signal.
    private func signalConnectedPeer() -> HelperTerminationOutcome {
        guard let peer = connection else { return .alreadyGone }
        let pid = xpc_connection_get_pid(peer)
        // A mach-service connection that has never been messaged has no
        // remote process yet, and reports pid 0 rather than failing.
        guard pid > 0 else { return .unknownPeer }
        guard kill(pid, SIGKILL) == 0 else {
            // Reading a pid says which process was connected, never that it
            // is still running: a helper that exits on its own in that
            // instant leaves nothing to signal. That is the outcome the
            // caller wanted, reached without us, so it must not be reported
            // as a refusal or skip the reconnect that drives recovery.
            if errno == ESRCH { return .alreadyGone }
            return .failed(String(cString: strerror(errno)))
        }
        connectionLog.notice(
            """
            terminated helper pid=\(pid, privacy: .public) \
            generation=\(self.connectionGeneration, privacy: .public)
            """
        )
        return .terminated(pid: pid)
    }

    /// Test seam: install a pre-made peer as the live connection, bypassing the
    /// full `connect()` setup, so a test can drive `request` against a
    /// controlled peer (e.g. an anonymous one that never replies) and exercise
    /// the real cancellation/gate paths deterministically. No ingress wiring:
    /// use `connectWithTestPeer` when the peer will reply.
    func setTestConnection(_ peer: xpc_connection_t) { connection = peer }

    /// Test seam: install a pre-made peer WITH full ingress wiring (so its
    /// replies are decoded and correlated), bumping the generation like a real
    /// connect. Lets a controlled peer answer requests.
    func connectWithTestPeer(_ peer: xpc_connection_t) { installPeer(peer) }

    /// Test seam: bump the connection generation in place (models a
    /// demand-reconnect replacing the peer) without tearing down the current
    /// one, so a test can change the generation mid-flight.
    func bumpGenerationForTesting() { connectionGeneration += 1 }

    /// Decide whether a method may be sent at all, and whether it may
    /// demand-`connect()` on the way. Throws before any connect, so a refused
    /// method never launches a daemon as a side effect.
    private func admit(_ method: String) throws -> Admission {
        switch mode {
        case .normal:
            return Admission(connectIfNeeded: true)

        case .recovering:
            // The ping is what launchd demand-launches the replacement for, so
            // it is the one method here that gets a connect.
            if method == RPCMethod.daemonPing.rawValue {
                return Admission(connectIfNeeded: true)
            }
            if method == RPCMethod.daemonShutdown.rawValue {
                return Admission(connectIfNeeded: false)
            }
            throw DaemonClientError.transport(
                "daemon wire version is incompatible; connection is recovering"
            )

        case .incompatible:
            guard method == RPCMethod.daemonShutdown.rawValue else {
                throw DaemonClientError.transport(
                    "daemon wire version is incompatible; connection is terminal"
                )
            }
            return Admission(connectIfNeeded: false)
        }
    }

    /// Resume a pending request with cancellation and drop it from the
    /// registry, the hook that makes an awaited `request` actually cancellable
    /// (e.g. an external timeout), since the XPC continuation is otherwise only
    /// resumed by a matching reply that may never arrive.
    private func cancelPendingRequest(_ envelopeId: UInt32) {
        if let continuation = pendingRequests.removeValue(forKey: envelopeId) {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Open or re-open the mach-service connection. Idempotent.
    /// Tearing down the old peer first clears `pendingSurfacePairs`
    /// so a daemon-relaunch-driven sequence rewind can't be
    /// confused with the prior generation's frames.
    func connect() {
        if connection != nil { return }
        let peer = xpc_connection_create_mach_service(
            machServiceName,
            nil,
            0
        )
        installPeer(peer)
    }

    /// Wire the per-connection ingress (event handler + ordered pump +
    /// accountant), resume the peer, bump the generation, and fire the reconnect
    /// hook on a reconnection. Shared by `connect()` and the test seam.
    private func installPeer(_ peer: xpc_connection_t) {
        // Ordered ingress: libxpc delivers callbacks serially on its own
        // queue, so yielding each event into a serial stream (rather than
        // spawning an unordered Task per callback) preserves arrival order
        // through to the actor-isolated drain.
        let (stream, continuation) = AsyncStream<XPCEventBox>.makeStream(
            bufferingPolicy: .unbounded
        )
        inbound = continuation
        xpc_connection_set_event_handler(peer) { event in
            continuation.yield(XPCEventBox(event: event))
        }
        inboundPump = Task { [weak self] in
            for await box in stream {
                await self?.handleEvent(box.event)
            }
        }
        accountant = SurfaceReleaseAccountant { [weak self] params in
            Task { await self?.sendReleaseNotification(params) }
        }
        xpc_connection_resume(peer)
        connection = peer
        startSweeperIfNeeded()
        connectionGeneration += 1
        // This generation identifies the GUI's current XPC connection. It
        // advances only when a peer is installed, not when one is invalidated,
        // so a stable generation plus no intervening invalidation entry is what
        // indicates the connection stayed open.
        connectionLog.info(
            "connected generation=\(self.connectionGeneration, privacy: .public)"
        )
        // Generation 1 is the initial connect; every later one is a
        // reconnection after an invalidation, so the daemon is fresh (its
        // in-memory anchor store is empty) and terminals must re-bind.
        if connectionGeneration > 1 { onReconnect?(connectionGeneration) }
    }

    /// Tear down the connection, used by tests and quit. Drops
    /// every in-flight request, every subscription, and every
    /// pending surface pair. Future RPCs error until `connect()`
    /// runs again.
    func disconnect() {
        if let connection {
            xpc_connection_cancel(connection)
        }
        connection = nil
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: DaemonClientError.transport("connection closed"))
        }
        let subs = subscriptions
        subscriptions.removeAll()
        for (_, record) in subs {
            finishSubscription(record)
        }
        teardownConnectionState()
        sweeperTask?.cancel()
        sweeperTask = nil
    }

    /// Drop the per-connection surface-lease state: parked pairs, token
    /// maps, the ordered pump, and the accountant. Leases still retained by
    /// the view model, content view, or in-flight command buffers can
    /// outlive this teardown, but their release sink targets the now-stopped
    /// accountant, so their eventual releases are no-ops; the reconnected
    /// connection's accountant starts fresh. The daemon meanwhile leaves
    /// those tokens' holds **pinned** in their epoch (orphaned, never
    /// force-freed). If enough disconnects pin enough slots to exhaust the
    /// pool, the daemon's frame loop then retires that epoch and rotates in
    /// a fresh recovery one.
    private func teardownConnectionState() {
        pendingSurfacePairs.removeAll()
        subscriptionTokens.removeAll()
        envelopeForToken.removeAll()
        inbound?.finish()
        inbound = nil
        inboundPump?.cancel()
        inboundPump = nil
        let accountant = self.accountant
        self.accountant = nil
        Task { await accountant?.stop() }
    }

    private func finishSubscription(_ record: SubscriptionRecord) {
        switch record {
        case let .pane(state):
            // End the pull stream: mark finished and resume any parked
            // puller with nil so the VM's `for await` exits.
            state.finished = true
            state.waiter?.resume(returning: nil)
            state.waiter = nil

        case let .raw(continuation):
            continuation.finish()
        }
    }

    /// Round-trip a one-shot request. Spawns a request envelope,
    /// records the continuation, and awaits the response.
    func request(method: String, params: Data?) async throws -> Data {
        try await requestReturningGeneration(method: method, params: params).data
    }

    /// Like `request`, but also returns the connection generation the request
    /// was SENT on, captured atomically (same actor turn) with reading the
    /// peer. A successful response implies no invalidation occurred during the
    /// request (an invalidation resumes pending requests with an error), so the
    /// send-time generation IS the generation that answered. There's no
    /// separate post-hoc sample a replacement could slip between. Used by the
    /// version handshake to pin remediation to the answering daemon instance.
    func requestReturningGeneration(
        method: String,
        params: Data?
    ) async throws -> (data: Data, generation: Int) {
        // `daemon.shutdown` must never demand-connect: it targets the SAME
        // daemon instance that returned the mismatched ping, and if that peer
        // already invalidated, connecting would demand-launch and then terminate
        // the UPDATED replacement. `daemon.ping` during a recovery is the
        // opposite case and does connect, because launching the replacement is
        // what it is for. `admit` carries that distinction.
        let admission = try admit(method)
        if admission.connectIfNeeded, connection == nil { connect() }
        guard let peer = connection else {
            throw DaemonClientError.transport(
                admission.connectIfNeeded
                    ? "connection unavailable"
                    : "incompatible daemon already disconnected; nothing to shut down"
            )
        }
        let generation = connectionGeneration
        let envelopeId = nextId
        nextId &+= 1
        let body: RPCEnvelope.Body = params.map { .params($0) } ?? .empty
        let envelope = RPCEnvelope(
            id: envelopeId,
            type: .request,
            method: method,
            body: body
        )
        // Cancellation-aware: the checked continuation is otherwise only
        // resumed by a matching reply, so a request the daemon never answers
        // (connection kept open) would hang forever. On cancellation, resume
        // once with `CancellationError` and drop the pending entry, so an
        // external timeout can actually bound the wait.
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[envelopeId] = continuation
                do {
                    let payload = try envelope.encode()
                    sendRPC(peer: peer, payload: payload)
                } catch {
                    pendingRequests.removeValue(forKey: envelopeId)
                    continuation.resume(
                        throwing: DaemonClientError.transport("encode: \(error)")
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelPendingRequest(envelopeId) }
        }
        return (data, generation)
    }

    /// Subscribe to a pane-lifecycle event stream. The XPC
    /// connection pairs JSON `surface.changed` evts with their
    /// side-band surface payloads before yielding `PaneEvent`s.
    func subscribe(
        method: String,
        params: Data?,
        paneId: String
    ) async throws -> (initial: Data, events: AsyncStream<PaneEvent>) {
        // No subscription is ever a bootstrap method, so neither non-normal mode
        // admits one: a stream opened while the daemon is being replaced would
        // never complete a reconnect handshake, and its events would be arriving
        // from a peer nothing has verified.
        guard case .normal = mode else {
            throw DaemonClientError.transport(
                "daemon wire version is incompatible; subscriptions are refused"
            )
        }
        if connection == nil { connect() }
        guard let peer = connection else {
            throw DaemonClientError.transport("connection unavailable")
        }
        let envelopeId = nextId
        nextId &+= 1
        let body: RPCEnvelope.Body = params.map { .params($0) } ?? .empty
        let envelope = RPCEnvelope(
            id: envelopeId,
            type: .request,
            method: method,
            body: body
        )
        // Consumer-pulled stream: it pulls from `state`, so while the
        // @MainActor VM is stalled surfaces coalesce to the newest while
        // control events queue losslessly (FIFO, no configured bound). The
        // VM stopping its iteration (pane closed) cancels the pull, which
        // sends the drain by request id.
        let state = PaneSubscriptionState(paneId: paneId)
        let stream = AsyncStream<PaneEvent>(
            unfolding: { await self.nextPaneEvent(envelopeId: envelopeId) },
            // Cleanup on the stream's OWN cancellation boundary, so it fires
            // even when a pull returns via the fast path (no suspension) and
            // the consumer is then cancelled. A per-pull cancellation
            // handler would miss that. Idempotent with any teardown path.
            onCancel: {
                Task { await self.paneConsumerEnded(envelopeId: envelopeId) }
            }
        )
        // The checked continuation isn't cancellation-aware, so a pane
        // closed before the subscribe response would leave the request and
        // the server subscription pending. Wrap the await: on cancellation,
        // resume once and send the drain by request id.
        let initial: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ready in
                pendingRequests[envelopeId] = ready
                subscriptions[envelopeId] = .pane(state)
                do {
                    let payload = try envelope.encode()
                    sendRPC(peer: peer, payload: payload)
                } catch {
                    pendingRequests.removeValue(forKey: envelopeId)
                    subscriptions.removeValue(forKey: envelopeId)
                    ready.resume(
                        throwing: DaemonClientError.transport("encode: \(error)")
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.handleSubscribeCancelled(envelopeId: envelopeId, paneId: paneId)
            }
        }
        return (initial, stream)
    }

    /// Pull the next event for a pane subscription (drives the VM's
    /// `AsyncStream(unfolding:)`). Lifecycle events come out in FIFO order;
    /// the latest surface follows; then `nil` ends the stream. If nothing
    /// is ready, park until an event arrives. On cancellation the stream's
    /// `onCancel` runs `paneConsumerEnded`, which finishes the state and
    /// resumes this parked pull with `nil`.
    private func nextPaneEvent(envelopeId: UInt32) async -> PaneEvent? {
        guard case let .pane(state) = subscriptions[envelopeId] else { return nil }
        if let ready = dequeuePaneEvent(state) { return ready }
        if state.finished { return nil }
        return await withCheckedContinuation { continuation in
            // Re-check on the actor: a deliver could have queued between the
            // early checks and here (no await between; re-checking costs nothing).
            if let ready = dequeuePaneEvent(state) {
                continuation.resume(returning: ready)
            } else if state.finished {
                continuation.resume(returning: nil)
            } else {
                state.waiter = continuation
            }
        }
    }

    /// The next event to hand a puller, or nil if none is ready.
    private func dequeuePaneEvent(_ state: PaneSubscriptionState) -> PaneEvent? {
        if !state.lifecycleQueue.isEmpty { return state.lifecycleQueue.removeFirst() }
        if let surface = state.latestSurface {
            state.latestSurface = nil
            return surface
        }
        return nil
    }

    /// Wake a parked puller with the next ready event, if any.
    private func wake(_ state: PaneSubscriptionState) {
        guard let waiter = state.waiter else { return }
        if state.finished {
            state.waiter = nil
            waiter.resume(returning: nil)
            return
        }
        if let ready = dequeuePaneEvent(state) {
            state.waiter = nil
            waiter.resume(returning: ready)
        }
    }

    /// Queue a lossless control event and wake any puller.
    private func deliverLifecycle(_ state: PaneSubscriptionState, _ event: PaneEvent) {
        state.lifecycleQueue.append(event)
        wake(state)
    }

    /// Replace the coalesced latest surface (older un-pulled one releases
    /// by ARC) and wake any puller.
    private func deliverLatestSurface(_ state: PaneSubscriptionState, _ event: PaneEvent) {
        state.latestSurface = event
        wake(state)
    }

    /// The VM stopped iterating (pane closed / task cancelled). Finish the
    /// stream, send the drain by request id, and drop per-subscription
    /// state. Idempotent.
    private func paneConsumerEnded(envelopeId: UInt32) {
        guard case let .pane(state) = subscriptions.removeValue(forKey: envelopeId) else { return }
        state.finished = true
        state.waiter?.resume(returning: nil)
        state.waiter = nil
        sendDrainNotification(paneId: state.paneId, subscribeRequestId: envelopeId)
        if let token = subscriptionTokens.removeValue(forKey: envelopeId) {
            envelopeForToken.removeValue(forKey: token)
        }
    }

    /// Subscribe cancelled before its response landed. Resume the pending
    /// request exactly once (a later response finds it already removed) and
    /// tear the server subscription down by request id.
    private func handleSubscribeCancelled(envelopeId: UInt32, paneId: String) {
        if let ready = pendingRequests.removeValue(forKey: envelopeId) {
            ready.resume(throwing: CancellationError())
        }
        if subscriptions[envelopeId] != nil {
            paneConsumerEnded(envelopeId: envelopeId)
        } else {
            // Cancelled before the subscription record existed; still send
            // the drain by request id so the daemon tears the server-side
            // subscription down even with no token/side-band.
            sendDrainNotification(paneId: paneId, subscribeRequestId: envelopeId)
        }
    }

    /// Raw subscription: yields `(method, params)` pairs from
    /// every event envelope received. Used by `app.commands`,
    /// whose events aren't tied to pane state and don't need the
    /// `(paneId, sequence)` correlation.
    func subscribeRaw(
        method: String,
        params: Data?
    ) async throws -> (initial: Data, events: AsyncStream<(String, Data)>) {
        // No subscription is ever a bootstrap method, so neither non-normal mode
        // admits one: a stream opened while the daemon is being replaced would
        // never complete a reconnect handshake, and its events would be arriving
        // from a peer nothing has verified.
        guard case .normal = mode else {
            throw DaemonClientError.transport(
                "daemon wire version is incompatible; subscriptions are refused"
            )
        }
        if connection == nil { connect() }
        guard let peer = connection else {
            throw DaemonClientError.transport("connection unavailable")
        }
        let envelopeId = nextId
        nextId &+= 1
        let body: RPCEnvelope.Body = params.map { .params($0) } ?? .empty
        let envelope = RPCEnvelope(
            id: envelopeId,
            type: .request,
            method: method,
            body: body
        )
        let (stream, continuation) = AsyncStream<(String, Data)>.makeStream()
        // Same reasoning as the pane subscribe above: the checked continuation
        // isn't cancellation-aware on its own, so a handshake a silent daemon
        // never answers would park forever and no external deadline could
        // bound it.
        let initial: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ready in
                pendingRequests[envelopeId] = ready
                subscriptions[envelopeId] = .raw(continuation: continuation)
                do {
                    let payload = try envelope.encode()
                    sendRPC(peer: peer, payload: payload)
                } catch {
                    pendingRequests.removeValue(forKey: envelopeId)
                    subscriptions.removeValue(forKey: envelopeId)
                    continuation.finish()
                    ready.resume(
                        throwing: DaemonClientError.transport("encode: \(error)")
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.handleRawSubscribeCancelled(envelopeId: envelopeId) }
        }
        return (initial, stream)
    }

    /// A raw subscribe was cancelled before its ack: drop the pending entry,
    /// resume it once, and finish the event stream. Unlike a pane
    /// subscription there's no drain to send: the daemon pins a raw
    /// subscriber to the subscribing connection (`app.commands` registers by
    /// connection id) and releases it when that connection goes away, and no
    /// wire method retires one early.
    private func handleRawSubscribeCancelled(envelopeId: UInt32) {
        if case let .raw(continuation) = subscriptions.removeValue(forKey: envelopeId) {
            continuation.finish()
        }
        pendingRequests.removeValue(forKey: envelopeId)?.resume(throwing: CancellationError())
    }

    // MARK: - Send

    private func sendRPC(peer: xpc_connection_t, payload: Data) {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(
            message,
            XPCWireKey.type,
            XPCWireKey.rpcValue
        )
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            xpc_dictionary_set_data(
                message,
                XPCWireKey.data,
                baseAddress,
                payload.count
            )
        }
        xpc_connection_send_message(peer, message)
    }

    /// Send a one-way notification (no `id`, no response): the surface-lease
    /// notifications. Silently no-ops if the connection is gone or the transport
    /// is incompatible (no traffic to the incompatible/replacement daemon).
    private func sendNotification(method: String, params: Data) {
        guard case .normal = mode, let peer = connection else { return }
        let envelope = RPCEnvelope(id: nil, type: .request, method: method, body: .params(params))
        guard let payload = try? envelope.encode() else { return }
        sendRPC(peer: peer, payload: payload)
    }

    private func sendReleaseNotification(_ params: SurfaceReleaseParams) {
        guard let data = try? JSONEncoder().encode(params) else { return }
        sendNotification(method: RPCMethod.paneSurfaceRelease.rawValue, params: data)
    }

    /// Tear the daemon's surface subscription down, keyed by the originating
    /// `pane.subscribe` request id, sent on any local termination of a
    /// pane subscription (stream cancelled, view closed).
    private func sendDrainNotification(paneId: String, subscribeRequestId: UInt32) {
        let params = SurfaceDrainParams(paneId: paneId, subscribeRequestId: subscribeRequestId)
        guard let data = try? JSONEncoder().encode(params) else { return }
        sendNotification(method: RPCMethod.paneSurfaceDrain.rawValue, params: data)
    }

    // MARK: - Receive

    private func handleEvent(_ event: xpc_object_t) async {
        let type = xpc_get_type(event)
        if type == XPC_TYPE_ERROR {
            // Connection terminated; reset state. Caller code that
            // re-issues a request will trigger a fresh `connect()`,
            // and launchd demand-launches the daemon on the next
            // send.
            //
            // Pass the error reason down so it is logged with the generation
            // and the pending-work counts, which are only in scope there.
            handleConnectionInvalidated(reason: describeXPCError(event))
            return
        }
        if type != XPC_TYPE_DICTIONARY { return }
        guard
            let kind = xpc_dictionary_get_string(event, XPCWireKey.type)
                .map({ String(cString: $0) })
        else { return }
        switch kind {
        case XPCWireKey.rpcValue:
            handleRPCMessage(event)

        case XPCWireKey.surfaceValue:
            await handleSurfacePayload(event)

        default:
            return
        }
    }

    private func handleRPCMessage(_ event: xpc_object_t) {
        var length: Int = 0
        guard
            let pointer = xpc_dictionary_get_data(event, XPCWireKey.data, &length),
            length > 0
        else { return }
        let buffer = UnsafeBufferPointer(
            start: pointer.assumingMemoryBound(to: UInt8.self),
            count: length
        )
        guard let envelope = try? RPCEnvelope.decode(Data(buffer)) else { return }
        // Responses and events always correlate back to a request id; a
        // frame without one isn't part of the inbound contract.
        guard let envelopeId = envelope.id else { return }
        switch envelope.type {
        case .response:
            guard let continuation = pendingRequests.removeValue(forKey: envelopeId)
            else { return }
            switch envelope.body {
            case let .result(data):
                // For a pane subscription, install the envelopeId → token
                // map from the ack BEFORE resuming, so a JSON
                // `surface.changed` that follows on this stream can find
                // its token, and drain any side-band that raced ahead.
                installSubscriptionToken(envelopeId: envelopeId, ackData: data)
                continuation.resume(returning: data)

            case .empty:
                continuation.resume(returning: Data())

            case let .error(error):
                // A failed initial-ack on a subscribe leaves a
                // dangling subscription record; finish it so the
                // GUI's `for await` loop terminates.
                if let record = subscriptions.removeValue(forKey: envelopeId) {
                    finishSubscription(record)
                }
                continuation.resume(
                    throwing: DaemonClientError.daemon(
                        code: error.code,
                        message: error.message
                    )
                )

            case .params:
                if let record = subscriptions.removeValue(forKey: envelopeId) {
                    finishSubscription(record)
                }
                continuation.resume(
                    throwing: DaemonClientError.transport(
                        "unexpected params on response"
                    )
                )
            }

        case .event:
            guard let record = subscriptions[envelopeId] else { return }
            guard case let .params(data) = envelope.body else { return }
            let methodName = envelope.method ?? ""
            switch record {
            case let .pane(state):
                switch PaneEventName(rawValue: methodName) {
                case .surfaceChanged:
                    guard let evt = try? JSONDecoder().decode(
                        SurfaceChangedEvent.self,
                        from: data
                    ) else { return }
                    // The token comes from this stream's envelopeId (the
                    // ack installed it, before this evt, via the ordered
                    // pump). Without it we can't pair; drop.
                    guard let token = subscriptionTokens[envelopeId] else { return }
                    tryFulfillSurfacePair(
                        paneId: state.paneId,
                        sequence: evt.sequence,
                        token: token,
                        inboundEvt: evt
                    )

                case .stateChanged:
                    guard let evt = try? JSONDecoder().decode(
                        StateChangedEvent.self,
                        from: data
                    ) else { return }
                    deliverLifecycle(state, .stateChanged(evt))

                case .orientationChanged:
                    guard let evt = try? JSONDecoder().decode(
                        OrientationChangedEvent.self,
                        from: data
                    ) else { return }
                    deliverLifecycle(state, .orientationChanged(evt))

                case nil:
                    return
                }

            case let .raw(continuation):
                continuation.yield((methodName, data))
            }

        case .request:
            return
        }
    }

    /// Install the `envelopeId → token` map (and its reverse) from a pane
    /// subscribe ack, synchronously before the response continuation
    /// resumes. A side-band that raced ahead already parked under the same
    /// token, so the JSON half resolves it once this map lets it compute
    /// the token. Non-pane subscriptions and tokenless acks are no-ops.
    private func installSubscriptionToken(envelopeId: UInt32, ackData: Data) {
        guard case .pane = subscriptions[envelopeId] else { return }
        guard let ack = try? JSONDecoder().decode(PaneSubscribeAck.self, from: ackData),
            let tokenString = ack.subscriptionToken,
            let token = UUID(uuidString: tokenString)
        else { return }
        subscriptionTokens[envelopeId] = token
        envelopeForToken[token] = envelopeId
    }

    private func handleSurfacePayload(_ event: xpc_object_t) async {
        guard let paneIdC = xpc_dictionary_get_string(event, XPCWireKey.paneId) else { return }
        let paneId = String(cString: paneIdC)
        let sequence = UInt64(xpc_dictionary_get_uint64(event, XPCWireKey.sequence))
        guard let tokenC = xpc_dictionary_get_string(event, XPCWireKey.subscriptionToken),
            let token = UUID(uuidString: String(cString: tokenC))
        else { return }
        guard let xpcSurface = xpc_dictionary_get_value(event, XPCWireKey.surface),
            let surface = IOSurfaceLookupFromXPCObject(xpcSurface)
        else { return }
        let leased = xpc_dictionary_get_bool(event, XPCWireKey.leased)
        let leaseEpoch = UInt64(xpc_dictionary_get_uint64(event, XPCWireKey.leaseEpoch))
        // Build the lease NOW: for a leased device frame its use-count bump
        // and accountant `acquire` happen before the pair resolves, so a
        // release (deinit) can never precede its acquire, even if the frame is
        // dropped; an unleased (sim / kill-switched) frame takes neither.
        let lease = await makeLease(
            paneId: paneId,
            token: token,
            leased: leased,
            leaseEpoch: leaseEpoch,
            generation: sequence,
            surface: surface
        )
        tryFulfillSurfacePair(paneId: paneId, sequence: sequence, token: token, inboundLease: lease)
    }

    /// Build a `SurfaceLease`. A leased device frame registers its
    /// generation with the accountant and installs a release sink; an
    /// unleased frame (simulator, or kill switch off) takes no use-count
    /// and no sink.
    private func makeLease(
        paneId: String,
        token: UUID,
        leased: Bool,
        leaseEpoch: UInt64,
        generation: UInt64,
        surface: IOSurfaceRef
    ) async -> SurfaceLease {
        guard leased, let accountant else {
            return SurfaceLease(
                surface: surface,
                paneId: paneId,
                subscriptionToken: token,
                leaseEpoch: leaseEpoch,
                generation: generation,
                onRelease: nil
            )
        }
        await accountant.acquire(
            paneId: paneId,
            subscriptionToken: token,
            leaseEpoch: leaseEpoch,
            generation: generation
        )
        return SurfaceLease(
            surface: surface,
            paneId: paneId,
            subscriptionToken: token,
            leaseEpoch: leaseEpoch,
            generation: generation,
            onRelease: { [weak accountant] key in
                Task {
                    await accountant?.release(
                        paneId: key.paneId,
                        subscriptionToken: key.subscriptionToken,
                        leaseEpoch: key.leaseEpoch,
                        generation: key.generation
                    )
                }
            }
        )
    }

    /// Slot reconciliation, keyed by `(paneId, sequence, token)` so two
    /// subscriptions on one pane never cross-deliver. JSON and side-band
    /// arrive as separate messages; whichever lands first parks its half.
    ///
    /// - Both halves present → yield once, drop the slot.
    /// - JSON-only → park; the sweeper times it out at 250ms and yields a
    ///   nil lease so the view keeps its last good frame.
    /// - Side-band-only → park; the sweeper drops it, and the lease
    ///   releases by ARC (freeing the daemon hold when leased; a no-op for
    ///   an unleased frame).
    private func tryFulfillSurfacePair(
        paneId: String,
        sequence: UInt64,
        token: UUID,
        inboundEvt: SurfaceChangedEvent? = nil,
        inboundLease: SurfaceLease? = nil
    ) {
        let key = PairKey(paneId: paneId, sequence: sequence, token: token)
        var slot = pendingSurfacePairs[key] ?? PendingSurfacePair(
            event: nil,
            lease: nil,
            insertedAt: pairStamp()
        )
        if let inboundEvt { slot.event = inboundEvt }
        if let inboundLease { slot.lease = inboundLease }
        if let evt = slot.event, let lease = slot.lease {
            pendingSurfacePairs.removeValue(forKey: key)
            yieldSurface(token: token, evt: evt, lease: lease)
            return
        }
        pendingSurfacePairs[key] = slot
    }

    /// Deliver a resolved frame to the one subscription that owns the
    /// token (never pane-wide), so two subscriptions on the same pane stay
    /// independent. Surfaces coalesce to the newest at the puller.
    private func yieldSurface(token: UUID, evt: SurfaceChangedEvent, lease: SurfaceLease?) {
        guard let envelopeId = envelopeForToken[token],
            case let .pane(state) = subscriptions[envelopeId]
        else { return }
        deliverLatestSurface(state, .surfaceChanged(evt, lease))
    }

    private func handleConnectionInvalidated(reason: String) {
        // Log the generation, the pending work, and the XPC reason before
        // discarding connection state. `interrupted` (the peer went away and
        // launchd may relaunch it) and `invalid` (the connection is gone for
        // good) point at different causes, so the reason is threaded down from
        // the frame above.
        connectionLog.notice(
            """
            invalidated generation=\(self.connectionGeneration, privacy: .public) \
            reason=\(reason, privacy: .public) \
            pendingRequests=\(self.pendingRequests.count, privacy: .public) \
            subscriptions=\(self.subscriptions.count, privacy: .public)
            """
        )
        connection = nil
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(
                throwing: DaemonClientError.transport("daemon connection invalidated")
            )
        }
        let subs = subscriptions
        subscriptions.removeAll()
        for (_, record) in subs {
            finishSubscription(record)
        }
        teardownConnectionState()
    }

    // MARK: - Sweeper

    /// Sweeper: drops pending half-pairs older than 250ms. If only
    /// the JSON evt is present, yields it with `nil` surface so the
    /// view keeps its last good frame. If only the side-band is
    /// present, it drops the pair and releases its lease by ARC.
    private func startSweeperIfNeeded() {
        guard sweeperTask == nil else { return }
        sweeperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                await self?.sweepPendingPairs()
            }
        }
    }

    private func sweepPendingPairs() {
        let now = pairStamp()
        for (key, slot) in pendingSurfacePairs {
            let age = now.timeIntervalSince(slot.insertedAt)
            if age < 0.25 { continue }
            pendingSurfacePairs.removeValue(forKey: key)
            if let evt = slot.event {
                // JSON-only timeout: yield a nil lease so the view keeps
                // its last good frame.
                yieldSurface(token: key.token, evt: evt, lease: nil)
            }
            // Side-band-only timeout: the slot (and its lease) is dropped
            // here; the lease releases by ARC, freeing the daemon hold when
            // it was leased.
        }
    }

    // MARK: - Helpers

    /// Per-process monotonic timestamp. Avoids `Date()` so the
    /// sweeper's age check doesn't drift on wall-clock changes.
    private func pairStamp() -> Date { Date() }
}

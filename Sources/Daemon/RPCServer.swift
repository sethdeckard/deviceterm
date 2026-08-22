// SPDX-License-Identifier: GPL-3.0-or-later
//
// RPCServer: listener actor for the daemon's Unix domain socket.
//
// Owns the listening fd and the map of accepted connections. The
// accept loop is driven by a `DispatchSourceRead` on the listener,
// not by a blocking thread: when the source fires we drain every
// pending connection via non-blocking `accept`, hand each new fd to
// a fresh `RPCConnection` actor, and add it to the connections map.
//
// Stop semantics:
//   - `stop()` cancels the accept source (which closes the listener
//     fd) and closes every active connection. The socket file at
//     `socketPath` is unlinked so a subsequent `start()` on the
//     same path doesn't trip the "path exists" guard.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum RPCServerError: Error, Equatable, Sendable {
    case alreadyStarted
    case notStarted
}

public actor RPCServer {
    private let socketPath: String
    private let methods: MethodRegistry
    private let authValidator: AuthValidator?
    private let provenance: ProvenanceContext?
    /// The live automation-grant store the `.automationTab` scope check
    /// consults on every request. Read OFF the registry (`methods.automationGrant`),
    /// never a separate parameter, so the ledger this server enforces against is
    /// the SAME one the grant/revoke handlers write and the advertiser reads, by
    /// construction. Nil disables the check (a granted session then can't reach
    /// the automation surface over UDS: fail closed).
    private let automationGrantStore: AutomationGrantStore?
    private let peerIdentityResolver: PeerIdentityResolver
    /// Nil makes each connection compose a resolver over `peerIdentityResolver`;
    /// inject one when a test must vary the ancestor prefix between requests.
    private let provenanceSnapshotResolver: ProvenanceSnapshotResolver?
    nonisolated private let acceptQueue: DispatchQueue
    private var listenerFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [UInt64: RPCConnection] = [:]
    private var nextConnectionId: UInt64 = 1
    private var started: Bool = false

    /// Diagnostic: how many connections the server is currently
    /// tracking. Tests use this to verify the connection-map is
    /// kept in sync with the read sources.
    public var activeConnectionCount: Int {
        connections.count
    }

    /// `authValidator` is the closure each accepted connection uses
    /// to validate `session.authenticate` frames. Production
    /// callers wire it to `SessionManager.validate(sessionId:,
    /// capability:)`; tests can pass nil to disable connection-
    /// layer auth (the dispatcher then rejects every `.session`-
    /// scoped call with `unauthorized`, useful for testing the
    /// rejection path).
    /// `peerIdentityResolver` reads the kernel-established identity of each
    /// accepted UDS peer (production: `LOCAL_PEERTOKEN`). Tests inject a
    /// synthetic resolver so provenance can be exercised without real
    /// sockets; the default is the real one.
    /// `provenanceSnapshotResolver` is the per-request seam that re-reads that
    /// identity and walks the caller's parent chain. Leave it nil and each
    /// connection composes one over `peerIdentityResolver`, so a synthetic peer
    /// keeps governing hop zero; inject one only to vary the ancestor prefix
    /// between requests.
    public init(
        socketPath: String,
        methods: MethodRegistry,
        authValidator: AuthValidator? = nil,
        peerIdentityResolver: @escaping PeerIdentityResolver = defaultPeerIdentityResolver,
        provenanceSnapshotResolver: ProvenanceSnapshotResolver? = nil
    ) {
        // Provenance is read OFF the registry (`methods.provenance`), never a
        // separate parameter, so the per-request lookup reads the same store
        // `session.bindTerminal` binds into. See `MethodRegistry.provenance`.
        // No `provenance != nil` precondition here (unlike `XPCServer`): a UDS
        // server configured with a validator but no provenance must FAIL CLOSED
        // gracefully (RPCConnection rejects every scoped request), not crash:
        // `provenanceFailsClosedWhenLookupAbsent` pins that behavior.
        self.socketPath = socketPath
        self.methods = methods
        self.authValidator = authValidator
        self.provenance = methods.provenance
        self.automationGrantStore = methods.automationGrant
        self.peerIdentityResolver = peerIdentityResolver
        self.provenanceSnapshotResolver = provenanceSnapshotResolver
        self.acceptQueue = DispatchQueue(label: "deviceterm.daemon.accept")
    }

    /// Bind + listen + start the accept loop. Throws if the socket
    /// path already has a filesystem entry (caller decides whether
    /// to unlink first).
    public func start() throws {
        guard !started else { throw RPCServerError.alreadyStarted }
        let fd = try UDSSocket.bindListener(at: socketPath)
        listenerFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        let fdCopy = fd
        let pathCopy = socketPath
        source.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.drainPendingAccepts()
            }
        }
        source.setCancelHandler {
            Darwin.close(fdCopy)
            _ = unlink(pathCopy)
        }
        source.resume()
        acceptSource = source
        started = true
    }

    /// Cancel the listener, close all active connections, unlink the
    /// socket file. Safe to call multiple times. Awaits the
    /// dispatch source's cancel handler before returning so callers
    /// observing the filesystem immediately afterward see the
    /// socket gone, not still-on-disk-pending-cleanup.
    public func stop() async {
        guard started else { return }
        started = false

        if let source = acceptSource {
            let fdCopy = listenerFd
            let pathCopy = socketPath
            // Replace the cancel handler set in `start()` with one
            // that additionally signals a continuation. `cancel()`
            // schedules this asynchronously on the accept queue;
            // without the continuation, callers would race against
            // the unlink and `fileExists` would still see the socket.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                source.setCancelHandler {
                    Darwin.close(fdCopy)
                    _ = unlink(pathCopy)
                    continuation.resume()
                }
                source.cancel()
            }
        }
        acceptSource = nil
        listenerFd = -1

        let toClose = Array(connections.values)
        connections.removeAll()
        for conn in toClose {
            await conn.close()
        }
    }

    /// Called by `RPCConnection` when it closes (EOF or fatal I/O).
    /// Idempotent: a connection that's already been removed is a
    /// no-op.
    func removeConnection(id: UInt64) {
        connections.removeValue(forKey: id)
    }

    // MARK: - Accept loop

    private func drainPendingAccepts() async {
        guard started else { return }
        while true {
            do {
                guard let clientFd = try UDSSocket.acceptOne(listenerFd: listenerFd) else {
                    return
                }
                let connectionId = nextConnectionId
                nextConnectionId &+= 1
                let connection = RPCConnection(
                    id: connectionId,
                    fd: clientFd,
                    methods: methods,
                    server: self,
                    authValidator: authValidator,
                    sessionProvenanceLookup: provenance?.lookup,
                    restorationGate: provenance?.restorationComplete,
                    automationGrantStore: automationGrantStore,
                    peerIdentityResolver: peerIdentityResolver,
                    provenanceSnapshotResolver: provenanceSnapshotResolver
                )
                connections[connectionId] = connection
                await connection.start()
            } catch {
                // Accept failed in a non-EAGAIN way; bail out of the
                // drain loop. The source will fire again later if
                // something interesting happens at the kernel layer.
                return
            }
        }
    }
}

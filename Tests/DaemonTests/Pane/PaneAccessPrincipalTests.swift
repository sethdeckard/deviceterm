// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// These tests pin how a dispatch context maps to a
// `PaneAccessPrincipal`.

private func withContext(
    _ context: DispatchPeerContext,
    session: SessionState? = nil,
    _ body: () -> Void
) {
    DispatchPeerContext.$current.withValue(
        session.map { context.withAuthenticatedSession($0) } ?? context
    ) {
        body()
    }
}

@Test
func validatedXPCPeerDerivesGUIPeer() async throws {
    let session = try await SessionManager().createSession(label: nil).state
    withContext(
        DispatchPeerContext(transport: .xpc, connectionId: 1, validatedGUIPeer: true),
        session: session
    ) {
        // Even with an authenticated session present, the validated GUI
        // peer is `.guiPeer` (spans sessions), not `.session`.
        #expect(PaneAccessPrincipal.fromCurrentDispatch() == .guiPeer)
    }
}

@Test
func udsNeverDerivesGUIPeerEvenIfBoolSet() async throws {
    let session = try await SessionManager().createSession(label: nil).state
    // Belt-and-braces: a UDS context with the bool somehow true must
    // still resolve to its session, never `.guiPeer`.
    withContext(
        DispatchPeerContext(transport: .uds, connectionId: 1, validatedGUIPeer: true),
        session: session
    ) {
        #expect(PaneAccessPrincipal.fromCurrentDispatch() == .session(session.id))
    }
}

@Test
func unvalidatedXPCWithSessionDerivesSession() async throws {
    let session = try await SessionManager().createSession(label: nil).state
    withContext(
        DispatchPeerContext(transport: .xpc, connectionId: 1, validatedGUIPeer: false),
        session: session
    ) {
        #expect(PaneAccessPrincipal.fromCurrentDispatch() == .session(session.id))
    }
}

@Test
func noAuthenticatedCallerDerivesNil() {
    // No session and no validated GUI peer → no principal.
    withContext(DispatchPeerContext(transport: .uds, connectionId: 1)) {
        #expect(PaneAccessPrincipal.fromCurrentDispatch() == nil)
    }
    // No bound context at all → nil.
    #expect(PaneAccessPrincipal.fromCurrentDispatch() == nil)
}

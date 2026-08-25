// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// physicalDevice.attach attribution: only the signature-validated GUI peer may
// name the target tab's session explicitly; every other caller (untrusted XPC,
// the CLI/shim over UDS, or one omitting sessionId) uses connection auth.
// Covers `resolveAttributionSession`'s trust + existence rules without a
// device. The trust gate here is the resolved verdict
// (`DispatchPeerContext.validatedGUIPeer`): `resolveAttributionSession` injects
// a stub trust decision, and `isTrustedGUIPeer` is tested directly against the
// resolved bool for both accept and reject. The underlying signature walk
// (`PeerIdentity.validateGUIPeer`) needs a real signed peer and is covered by
// the signed-bundle / manual validation track, not by these injected stubs.

private func withContext(
    transport: DispatchPeerContext.Transport,
    originating: UUID?,
    _ body: () async -> Void
) async {
    await DispatchPeerContext.$current.withValue(
        DispatchPeerContext(transport: transport, connectionId: 1)
    ) {
        await SessionDispatchContext.$originatingSessionId.withValue(originating?.uuidString) {
            await body()
        }
    }
}

@Test
func trustedGUIPeerHonorsAnExplicitExistingSession() async throws {
    let manager = SessionManager()
    let target = try await manager.makeSessionState(label: nil)
    let connection = UUID() // a *different* connection-auth session
    await withContext(transport: .xpc, originating: connection) {
        let params = PhysicalDeviceMethods.AttachParams(deviceId: "d", sessionId: target.id.uuidString)
        let resolved = await PhysicalDeviceMethods.resolveAttributionSession(
            params: params, sessionManager: manager, isTrustedGUIPeer: { _ in true }
        )
        #expect(resolved == target.id, "the trusted GUI should attribute to the named session, not connection-auth")
    }
}

@Test
func trustedPeerIgnoresAnUnknownSessionAndFallsBackToConnectionAuth() async {
    let manager = SessionManager()
    let connection = UUID()
    await withContext(transport: .xpc, originating: connection) {
        // A sessionId that names no real session is not honored, even when trusted.
        let params = PhysicalDeviceMethods.AttachParams(deviceId: "d", sessionId: UUID().uuidString)
        let resolved = await PhysicalDeviceMethods.resolveAttributionSession(
            params: params, sessionManager: manager, isTrustedGUIPeer: { _ in true }
        )
        #expect(resolved == connection)
    }
}

@Test
func untrustedXPCPeerCannotNameAnotherSession() async throws {
    // An XPC peer that fails the GUI signature check must NOT be able to name
    // another session; it falls back to its own connection-auth session, the
    // same cross-session boundary UDS protects.
    let manager = SessionManager()
    let victim = try await manager.makeSessionState(label: nil) // a real, other session
    let attacker = UUID()
    await withContext(transport: .xpc, originating: attacker) {
        let params = PhysicalDeviceMethods.AttachParams(deviceId: "d", sessionId: victim.id.uuidString)
        let resolved = await PhysicalDeviceMethods.resolveAttributionSession(
            params: params, sessionManager: manager, isTrustedGUIPeer: { _ in false }
        )
        #expect(resolved == attacker, "an untrusted XPC peer must not attribute to another session")
    }
}

@Test
func isTrustedGUIPeerReadsResolvedVerdict() {
    // The gate reads the resolved verdict
    // (`DispatchPeerContext.validatedGUIPeer`). UDS and an unvalidated XPC
    // peer are rejected; a validated XPC peer is accepted. The
    // `transport == .xpc` conjunct is belt-and-braces: a UDS context with
    // the bool set is still refused.
    #expect(!PhysicalDeviceMethods.isTrustedGUIPeer(.init(transport: .uds, connectionId: 1)))
    #expect(!PhysicalDeviceMethods.isTrustedGUIPeer(.init(transport: .xpc, connectionId: 2, validatedGUIPeer: false)))
    #expect(PhysicalDeviceMethods.isTrustedGUIPeer(.init(transport: .xpc, connectionId: 3, validatedGUIPeer: true)))
    #expect(!PhysicalDeviceMethods.isTrustedGUIPeer(.init(transport: .uds, connectionId: 4, validatedGUIPeer: true)))
}

@Test
func realGateIgnoresExplicitSessionForUDS() async throws {
    // End-to-end through the REAL isTrustedGUIPeer: a UDS caller's explicit
    // sessionId is ignored (UDS → untrusted → connection-auth).
    let manager = SessionManager()
    let target = try await manager.makeSessionState(label: nil)
    let connection = UUID()
    await withContext(transport: .uds, originating: connection) {
        let params = PhysicalDeviceMethods.AttachParams(deviceId: "d", sessionId: target.id.uuidString)
        let resolved = await PhysicalDeviceMethods.resolveAttributionSession(params: params, sessionManager: manager)
        #expect(resolved == connection)
    }
}

@Test
func attachParamsDecodesWithAndWithoutSessionId() throws {
    // A deviceId-only body (CLI/shim, or an older client) still decodes;
    // sessionId is optional.
    let bare = try JSONDecoder().decode(
        PhysicalDeviceMethods.AttachParams.self,
        from: Data(#"{"deviceId":"d"}"#.utf8)
    )
    #expect(bare.deviceId == "d")
    #expect(bare.sessionId == nil)
    let withSession = try JSONDecoder().decode(
        PhysicalDeviceMethods.AttachParams.self,
        from: Data(#"{"deviceId":"d","sessionId":"S"}"#.utf8)
    )
    #expect(withSession.sessionId == "S")
}

@Test
func noExplicitSessionUsesConnectionAuth() async {
    let manager = SessionManager()
    let connection = UUID()
    await withContext(transport: .xpc, originating: connection) {
        let params = PhysicalDeviceMethods.AttachParams(deviceId: "d")
        let resolved = await PhysicalDeviceMethods.resolveAttributionSession(params: params, sessionManager: manager)
        #expect(resolved == connection)
    }
}

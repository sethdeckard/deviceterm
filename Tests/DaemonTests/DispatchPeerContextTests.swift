// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// DispatchPeerContext: the caller-identity record threaded through
// every dispatched method via a task-local. The dispatcher binds
// it; handlers read it through `DispatchPeerContext.current`.
//
// Tests pin: TaskLocal propagates across `await` boundaries
// inside the same task; nested binds shadow correctly; the
// initializer assigns fields verbatim; `withAuthenticatedSession`
// preserves the other fields.

@Test
func defaultCurrentIsNil() {
    #expect(DispatchPeerContext.current == nil)
}

@Test
func bindCarriesAcrossAwait() async {
    let context = DispatchPeerContext(
        transport: .uds,
        connectionId: 42
    )
    let captured: (transport: DispatchPeerContext.Transport, connectionId: UInt64)?
        = await DispatchPeerContext.$current.withValue(context) {
            await asyncReadCurrent()
        }
    #expect(captured?.transport == .uds)
    #expect(captured?.connectionId == 42)
}

@Test
func nestedBindShadows() {
    let outer = DispatchPeerContext(transport: .uds, connectionId: 1)
    let inner = DispatchPeerContext(transport: .xpc, connectionId: 2)
    DispatchPeerContext.$current.withValue(outer) {
        #expect(DispatchPeerContext.current?.connectionId == 1)
        DispatchPeerContext.$current.withValue(inner) {
            #expect(DispatchPeerContext.current?.connectionId == 2)
        }
        #expect(DispatchPeerContext.current?.connectionId == 1)
    }
    #expect(DispatchPeerContext.current == nil)
}

@Test
func withAuthenticatedSessionPreservesOtherFields() {
    let base = DispatchPeerContext(
        transport: .xpc,
        connectionId: 7
    )
    #expect(base.authenticatedSession == nil)
    let session = SessionState(
        id: UUID(),
        capabilityVerifier: CapabilityVerifier(
            for: (try? Capability.random()) ?? Capability(bytes: Data(repeating: 0, count: 32))
        ),
        shortId: "abcd12",
        label: "L",
        name: "N",
        createdAt: Date(timeIntervalSince1970: 0),
        role: .agent,
        ownerPID: 100
    )
    let updated = base.withAuthenticatedSession(session)
    #expect(updated.transport == .xpc)
    #expect(updated.connectionId == 7)
    #expect(updated.authenticatedSession?.id == session.id)
}

@Test
func transportRawValuesAreStable() async {
    let uds: String = await Task { DispatchPeerContext.Transport.uds.rawValue }.value
    let xpc: String = await Task { DispatchPeerContext.Transport.xpc.rawValue }.value
    #expect(uds == "uds")
    #expect(xpc == "xpc")
}

// MARK: - Helpers

/// Reads `DispatchPeerContext.current` after an arbitrary
/// async hop so the test confirms TaskLocal carries across
/// suspension within the same task tree.
private func asyncReadCurrent() async
    -> (transport: DispatchPeerContext.Transport, connectionId: UInt64)? {
    try? await Task.sleep(nanoseconds: 1)
    guard let value = DispatchPeerContext.current else { return nil }
    return (value.transport, value.connectionId)
}

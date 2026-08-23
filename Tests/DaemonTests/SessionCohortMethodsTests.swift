// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionCohortMethodsTests: the `session.setCohort` handler's wire
// validation, driven through the real `defaultRegistry(...)`.
//
// The handler's contract is that a malformed payload is a *definite*
// pre-mutation rejection (`invalidParams`), distinguishable from an
// indeterminate transport loss. The case worth pinning is `replaces`: an
// absent value and an unparseable one are different requests, and collapsing
// them (the optional-flatMap shape) would execute a replacement request with
// non-replacement semantics — leaving the outgoing cohort alive, or refusing
// on foreign membership when the caller did everything right.

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

private func setCohortHandler() throws -> MethodRegistry.Handler {
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: SessionManager(),
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator()
    )
    guard let handler = registry.handler(for: RPCMethod.sessionSetCohort.rawValue) else {
        throw SetCohortTestError.notRegistered
    }
    return handler
}

private enum SetCohortTestError: Error { case notRegistered }

/// Invoke the handler under a bound validated-GUI dispatch context, mirroring
/// the transport dispatcher.
private func invokeSetCohort(
    _ handler: MethodRegistry.Handler,
    params: [String: Any]
) async throws -> Data {
    let context = DispatchPeerContext(
        transport: .xpc,
        connectionId: 1,
        authenticatedSession: nil,
        validatedGUIPeer: true
    )
    let payload = try JSONSerialization.data(withJSONObject: params)
    return try await DispatchPeerContext.$current.withValue(context) {
        try await handler(payload)
    }
}

@Test
func setCohortIsValidatedGUIScoped() {
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: SessionManager(),
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator()
    )
    #expect(registry.scope(of: RPCMethod.sessionSetCohort.rawValue) == .validatedGUI)
}

@Test
func aMalformedReplacesIsRefusedAsInvalidParams() async throws {
    let handler = try setCohortHandler()
    let memberId = UUID().uuidString
    do {
        _ = try await invokeSetCohort(handler, params: [
            "cohortId": UUID().uuidString,
            "revision": 1,
            "members": [memberId],
            "representative": memberId,
            "replaces": "not-a-uuid"
        ])
        Issue.record("expected a malformed replaces to be refused")
    } catch let error as RPCMethodError {
        #expect(error.code == RPCMethodError.invalidParamsCode)
        #expect(error.message.contains("replaces"))
    } catch {
        Issue.record("expected RPCMethodError, got \(error)")
    }
}

@Test
func anAbsentReplacesPassesReplacesValidation() async throws {
    // The same request without `replaces` gets past that check and fails
    // later, on member liveness — proving the refusal above is about the
    // malformed field and not the payload's general shape.
    let handler = try setCohortHandler()
    let memberId = UUID().uuidString
    do {
        _ = try await invokeSetCohort(handler, params: [
            "cohortId": UUID().uuidString,
            "revision": 1,
            "members": [memberId],
            "representative": memberId
        ])
        Issue.record("expected an unknown member to be refused")
    } catch let error as RPCMethodError {
        #expect(error.code == RPCMethodError.invalidParamsCode)
        #expect(error.message.contains("not a live session"))
    } catch {
        Issue.record("expected RPCMethodError, got \(error)")
    }
}

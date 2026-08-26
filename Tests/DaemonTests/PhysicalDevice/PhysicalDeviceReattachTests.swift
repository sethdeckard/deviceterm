// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// Re-attaching a physical device that is already mirrored.
// Bringing up a backend resolves the device, raises a tunnel, and bootstraps
// services. It is the least reliable part of an attach, and it has to run
// before `createPane`, because resolving inside the coordinator would hold its
// actor for the whole bring-up. A re-attach that `createPane` answers from the
// existing record needs none of it, so a hiccup there must not be the answer.
// That combination isn't hypothetical: the GUI re-attaches every device pane
// when it reconnects, including a reconnect the same daemon survived with its
// records intact, so a transient resolution failure would turn a healthy
// mirror into a failed pane needing a manual retry.

/// A physical-device coordinator that can find nothing, so `resolveBackend`
/// fails the way a device-list, tunnel, or service-bootstrap hiccup does.
private func coordinatorFindingNoDevices() -> PhysicalDeviceCoordinator {
    PhysicalDeviceCoordinator(listDevices: { [] })
}

@Test
func aReAttachIsAnsweredFromTheExistingPaneEvenWhenResolutionFails() async throws {
    let panes = PaneCoordinator()
    let sessions = SessionManager()
    let session = try await sessions.createSession(label: nil)
    // The handler creates panes with `requireConcreteIncarnation`, so the
    // session has to be admitted with a real incarnation and replayed into the
    // coordinator's active map, the way the composition root wires it.
    guard case let .ready(pinned) = await sessions.admission(for: session.state.id),
        let incarnation = pinned else {
        Issue.record("expected the session to be admitted with an incarnation")
        return
    }
    await sessions.setPaneActivator { sid, inc in
        await panes.noteSessionActive(sid, incarnation: inc)
    }
    let mounted = try await panes.createPane(
        target: .device(deviceId: "dev-1"),
        sessionId: session.state.id,
        ownerIncarnation: incarnation,
        requireConcreteIncarnation: true,
        acquire: {
            PaneCoordinator.AcquiredBackend(
                backend: StubDeviceBackend(),
                family: DeviceFamily.unknown.rawValue,
                deviceType: nil
            )
        }
    )

    let handler = PhysicalDeviceMethods.attach(
        physicalDeviceCoordinator: coordinatorFindingNoDevices(),
        paneCoordinator: panes,
        sessionManager: sessions
    )
    let params = try JSONEncoder().encode(
        PhysicalDeviceMethods.AttachParams(deviceId: "dev-1")
    )
    let data = try await SessionDispatchContext.$originatingSessionId.withValue(
        session.state.id.uuidString
    ) {
        try await handler(params)
    }

    let response = try JSONDecoder().decode(PaneMethods.CreateResponse.self, from: data)
    #expect(
        response.paneId == mounted.paneId.uuidString,
        "the re-attach should be answered from the record that already exists"
    )
    let live = await panes.liveOwnerships()
    #expect(
        live.map(\.paneId) == [mounted.paneId],
        "the pane the re-attach was answered from should still be the only one"
    )
}

@Test
func aFreshAttachStillReportsWhyResolutionFailed() async throws {
    // The other side of deferring the failure: with no record to fall back on,
    // `acquire` runs and the resolution error is the answer, reported as
    // itself rather than as some generic create failure.
    let panes = PaneCoordinator()
    let sessions = SessionManager()
    let session = try await sessions.createSession(label: nil)
    await sessions.setPaneActivator { sid, inc in
        await panes.noteSessionActive(sid, incarnation: inc)
    }
    let handler = PhysicalDeviceMethods.attach(
        physicalDeviceCoordinator: coordinatorFindingNoDevices(),
        paneCoordinator: panes,
        sessionManager: sessions
    )
    let params = try JSONEncoder().encode(
        PhysicalDeviceMethods.AttachParams(deviceId: "absent")
    )
    await SessionDispatchContext.$originatingSessionId.withValue(session.state.id.uuidString) {
        await #expect(throws: RPCMethodError.self) { try await handler(params) }
    }
}

/// Stands in for the `devicectl` keepalive subprocess so a test can see
/// whether the tunnel was torn down.
private final class FakeKeepaliveHandle: KeepaliveHandle, @unchecked Sendable {
    private(set) var interrupted = false
    var isRunning: Bool { !interrupted }

    func interrupt() { interrupted = true }
}

@Test
func aRefusedCrossSessionAttachLeavesTheOwnersTunnelAlone() async throws {
    // The cleanup on a refused create releases what this attach retained. With
    // resolution deferred there may be nothing: `resolveBackend` balances its
    // own retain on failure, so a releasing cleanup would decrement the retain
    // held by whoever is already mirroring the device, and one unit is all it
    // takes to tear their tunnel down. A create refused because another live
    // session owns the device is exactly when that retain belongs to someone
    // else.
    let handle = FakeKeepaliveHandle()
    let keepalive = TunnelKeepalive(spawner: { _ in handle })
    let coordinator = PhysicalDeviceCoordinator(
        keepalive: keepalive,
        listDevices: { [] }
    )
    let panes = PaneCoordinator()
    let sessions = SessionManager()
    await sessions.setPaneActivator { sid, inc in
        await panes.noteSessionActive(sid, incarnation: inc)
    }
    // The owner: a live session already mirroring the device, holding the
    // tunnel the way a real attach would.
    let owner = try await sessions.createSession(label: nil)
    guard case let .ready(pinned) = await sessions.admission(for: owner.state.id),
        let ownerIncarnation = pinned else {
        Issue.record("expected the owning session to be admitted with an incarnation")
        return
    }
    keepalive.retain(udid: "dev-1")
    _ = try await panes.createPane(
        target: .device(deviceId: "dev-1"),
        sessionId: owner.state.id,
        ownerIncarnation: ownerIncarnation,
        requireConcreteIncarnation: true,
        acquire: {
            PaneCoordinator.AcquiredBackend(
                backend: StubDeviceBackend(),
                family: DeviceFamily.unknown.rawValue,
                deviceType: nil
            )
        }
    )

    // A second, different live session attaches the same device. Resolution
    // fails, then the create is refused because the owner is still alive.
    let other = try await sessions.createSession(label: nil)
    let handler = PhysicalDeviceMethods.attach(
        physicalDeviceCoordinator: coordinator,
        paneCoordinator: panes,
        sessionManager: sessions
    )
    let params = try JSONEncoder().encode(
        PhysicalDeviceMethods.AttachParams(deviceId: "dev-1")
    )
    await SessionDispatchContext.$originatingSessionId.withValue(other.state.id.uuidString) {
        await #expect(throws: RPCMethodError.self) { try await handler(params) }
    }
    #expect(!handle.interrupted, "the owner's tunnel must survive a refused attach")
}

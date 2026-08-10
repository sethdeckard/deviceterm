// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

// Device-attach branch of the shim.event handler: a `devicectl device
// install|process launch` the shim observed becomes a `pane.attach`
// back-channel command mounting the resolved device under the calling
// session. These tests drive the handler closure directly (the
// AppCommandCoordinator is otherwise hidden behind the wire harness),
// injecting a stub device resolver so the path is hermetic: no live
// tunnel, no connected device.

private func deviceAttachParams(
    sessionId: String,
    cap: String,
    deviceIdentifier: String? = "My iPhone"
) throws -> Data {
    try JSONEncoder().encode(
        ShimMethods.EventParams(
            event: ShimEventType.deviceAttach.rawValue,
            sessionId: sessionId,
            cap: cap,
            invokedAs: "xcrun",
            argv: [
                "xcrun", "devicectl", "device", "install", "app",
                "--device", "My iPhone", "/tmp/My.app"
            ],
            deviceIdentifier: deviceIdentifier
        )
    )
}

private func makeHandler(
    sessionManager: SessionManager,
    appCommands: AppCommandCoordinator,
    session: SessionState,
    resolveDeviceId: @escaping @Sendable (String) async -> String?
) -> MethodRegistry.Handler {
    let inner = ShimMethods.event(
        sessionManager: sessionManager,
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator(),
        physicalDeviceCoordinator: PhysicalDeviceCoordinator(),
        appCommandCoordinator: appCommands,
        resolveDeviceId: resolveDeviceId
    )
    // These tests drive the handler closure directly, bypassing the transport
    // dispatcher that would bind the caller's context. Bind one here so the
    // payload-matches-connection guard sees the connection authenticated as
    // the same session the params name (production always has this context).
    return { params in
        let context = DispatchPeerContext(
            transport: .uds,
            connectionId: 1,
            authenticatedSession: session
        )
        return try await DispatchPeerContext.$current.withValue(context) {
            try await inner(params)
        }
    }
}

@Test
func deviceAttachPublishesPaneAttachForResolvedDevice() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let appCommands = AppCommandCoordinator()
    let (stream, _) = await appCommands.subscribe(connectionId: 1)
    let handler = makeHandler(
        sessionManager: manager,
        appCommands: appCommands,
        session: state,
        resolveDeviceId: { _ in "fdab::42" }
    )
    let params = try deviceAttachParams(
        sessionId: state.id.uuidString,
        cap: created.capability.token
    )

    // The handler awaits the GUI's ack, so run it concurrently and feed
    // the ack once we've observed the published command.
    let handlerTask = Task { try await handler(params) }

    var iterator = stream.makeAsyncIterator()
    let command = try #require(await iterator.next())
    #expect(command.kind == .paneAttach)
    #expect(command.originatingSessionId == state.id.uuidString)
    let attach = try JSONDecoder().decode(
        AppCommandParams.PaneAttach.self,
        from: command.params
    )
    #expect(attach.target == .device(deviceId: "fdab::42"))
    // Contextual auto-attach relinks latest-wins.
    #expect(attach.relinkExisting)

    await appCommands.deliverResult(.ok(commandId: command.commandId), from: 1)
    let ack = try JSONDecoder().decode(
        ShimMethods.EventResponse.self,
        from: try await handlerTask.value
    )
    #expect(ack.success)
}

@Test
func deviceAttachWithUnresolvableSpecAcksWithoutPublishing() async throws {
    // Multi-device host with no match (resolver returns nil): the
    // devicectl command already ran; the auto-attach is best-effort, so
    // the event still acks and nothing is published.
    let manager = SessionManager()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let appCommands = AppCommandCoordinator()
    let handler = makeHandler(
        sessionManager: manager,
        appCommands: appCommands,
        session: state,
        resolveDeviceId: { _ in nil }
    )
    let params = try deviceAttachParams(
        sessionId: state.id.uuidString,
        cap: created.capability.token
    )
    let ack = try JSONDecoder().decode(
        ShimMethods.EventResponse.self,
        from: try await handler(params)
    )
    #expect(ack.success)
    let pending = await appCommands.pendingCount
    #expect(pending == 0)
}

@Test
func deviceAttachWithoutIdentifierIsInvalidParams() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let handler = makeHandler(
        sessionManager: manager,
        appCommands: AppCommandCoordinator(),
        session: state,
        resolveDeviceId: { _ in "fdab::1" }
    )
    let params = try deviceAttachParams(
        sessionId: state.id.uuidString,
        cap: created.capability.token,
        deviceIdentifier: nil
    )
    await #expect(throws: RPCMethodError.self) {
        _ = try await handler(params)
    }
}

@Test
func deviceAttachRejectsWrongCapabilityBeforePublishing() async throws {
    // The provenance gate runs before resolution/publish: a bad cap
    // throws and never reaches the back-channel.
    let manager = SessionManager()
    let created = try await manager.createSession(label: "tab")
    let state = created.state
    let stranger = try Capability.random()
    let appCommands = AppCommandCoordinator()
    let handler = makeHandler(
        sessionManager: manager,
        appCommands: appCommands,
        session: state,
        resolveDeviceId: { _ in "fdab::1" }
    )
    let params = try deviceAttachParams(
        sessionId: state.id.uuidString,
        cap: stranger.token
    )
    await #expect(throws: RPCMethodError.self) {
        _ = try await handler(params)
    }
    let pending = await appCommands.pendingCount
    #expect(pending == 0)
}

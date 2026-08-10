// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
@testable import Daemon
import DaemonTestSupport
import Foundation
import Testing

// The joined contract TabContentViewController.discoverBootedSims() depends on: an
// owned sim must surface via device.list(scope:"owned") with BOTH
// ownedBySession == its session AND state == "Booted". ShimMethodsTests
// proves the ownership half; DeviceMethodsTests proves the list-shape
// half; neither proves both hold for a genuinely booted device.
//
// This runs in the deliberate `make test-live` track, which provisions a
// clean booted sim, so the test *uses* that sim (no boot/shutdown of
// its own, no clobbering the developer's sims) and requires one loudly
// rather than skipping.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

@Test
func ownedBootedSimSurfacesInDeviceListWithBootedState() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let udid = booted.udid

    let manager = SessionManager()
    let coordinator = DeviceCoordinator()
    let created = try await manager.createSession(label: "e2e")
    let state = created.state

    let path = tempSocketPath(prefix: "deviceterm-e2e")
    let server = try await startServer(
        path: path,
        sessionManager: manager,
        deviceCoordinator: coordinator
    )
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    // shim.event "booted" carrying this session's cap → records ownership
    // of the already-booted sim against the session.
    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "shim.event",
        body: .params(
            try paramsBytes(
            ShimMethods.EventParams(
            event: "booted",
            sessionId: state.id.uuidString,
            cap: created.capability.token,
            udid: udid,
            deviceName: booted.name,
            runtime: booted.runtimeIdentifier,
            invokedAs: "xcrun",
            argv: ["xcrun", "simctl", "boot", udid]
        )
            )
            )
    )
        )
    guard case .result = try client.receive().body else {
        Issue.record("shim.event booted should ack")
        return
    }

    // device.list(scope:"owned") must now show the sim with both halves
    // of the contract satisfied.
    try client.send(
        RPCEnvelope(
        id: 2,
        type: .request,
        method: "device.list",
        body: .params(try paramsBytes(DeviceMethods.ListParams(scope: "owned")))
    )
        )
    guard case let .result(bytes) = try client.receive().body else {
        Issue.record("device.list owned should return a result")
        return
    }
    let entries = try JSONDecoder().decode(
        [DeviceMethods.ListEntry].self,
        from: bytes
    )
    let entry = try #require(
        entries.first { $0.udid.lowercased() == udid.lowercased() },
        "owned list is missing the booted sim"
    )
    #expect(entry.ownedBySession == state.id.uuidString)
    #expect(entry.state == "Booted")
}

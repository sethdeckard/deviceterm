// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
@testable import Daemon
import Foundation
import Testing

// PaneCoordinator-level tests focused on error paths that don't
// require a live simulator. Sim-pane bridge behavior against a real
// device is covered by the CoreSimulatorBridge tests.

// MARK: - Sim pane error paths

@Test
func createSimRejectsMalformedUDID() async throws {
    let coordinator = PaneCoordinator()
    await #expect(throws: PaneError.malformedUDID(udid: "")) {
        _ = try await coordinator.createSim(sessionId: UUID(), udid: "")
    }
    await #expect(throws: PaneError.malformedUDID(udid: "abc")) {
        _ = try await coordinator.createSim(sessionId: UUID(), udid: "abc")
    }
}

// Bridge-failing path: a well-formed but non-existent UDID surfaces
// as `deviceNotFound`. Gated on the probe so degraded hosts skip.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func createSimRejectsUnknownUDID() async throws {
    let coordinator = PaneCoordinator()
    let bogus = "DEADBEEF-DEAD-DEAD-DEAD-DEADBEEFDEAD"
    await #expect(throws: PaneError.deviceNotFound(udid: bogus.lowercased())) {
        _ = try await coordinator.createSim(sessionId: UUID(), udid: bogus)
    }
}

@Test
func subscribeOnUnknownPaneThrows() async throws {
    let coordinator = PaneCoordinator()
    let strayId = UUID()
    await #expect(throws: PaneError.notFound(paneId: strayId)) {
        _ = try await coordinator.subscribe(paneId: strayId, as: .guiPeer)
    }
}

@Test
func closeOnUnknownPaneIsNoOp() async {
    let coordinator = PaneCoordinator()
    let outcome = await coordinator.close(paneId: UUID(), as: .guiPeer, mode: .detach)
    #expect(outcome.udidToShutdown == nil)
    let count = await coordinator.paneCount
    #expect(count == 0)
}

// MARK: - Wire-error mapping

@Test
func paneAlreadyAttachedMapsToInvalidParamsWithUDIDInMessage() {
    // `paneAlreadyAttached` is the daemon's signal that a cross-
    // session create was attempted for a udid that already has a
    // live pane under another session. The RPC layer maps it to
    // `invalidParams` with the udid in the message so a CLI caller
    // sees a hint they can act on (look up the existing owner via
    // `deviceterm panes list`, or ask the human to re-link via GUI
    // drag; no CLI verb performs a cross-session move).
    let udid = "7db632b6-86d3-437d-b567-36a80e59788b"
    let mapped = PaneMethods.mapPaneError(
        .paneAlreadyAttached(udid: udid, ownerSessionId: UUID())
    )
    #expect(mapped.code == RPCMethodError.invalidParamsCode)
    #expect(mapped.message.contains(udid))
    #expect(mapped.message.contains("different session"))
}

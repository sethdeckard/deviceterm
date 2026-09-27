// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
@testable import Daemon
import Foundation
import Testing

// The family the acquirer classifies from the real device type is what
// decides the crown flag a sim pane advertises, so a pane created through
// the bridge reports `crown` only when the booted device is a watch, and
// the coordinator refuses the verb on any other family before it reaches
// SimulatorKit. Live track because the classification reads the device's
// type identifier from CoreSimulator and the backend is built from real
// bridge handles.

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

private func bootedDeviceIsWatch() -> Bool {
    let identifier = (try? SimDeviceHandle.singleBootedDevice())?
        .deviceTypeIdentifier ?? ""
    return DeviceFamilyClassifier.classify(identifier) == .watch
}

@Test
func aSimPaneAdvertisesCrownOnlyForAWatch() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed: the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim: run via `make test-live`"
    )
    let family = DeviceFamilyClassifier.classify(booted.deviceTypeIdentifier)
    let coordinator = PaneCoordinator()
    let result = try await coordinator.createSim(
        sessionId: UUID(),
        udid: booted.udid
    )
    #expect(result.family == family.rawValue)
    #expect(result.capabilities.crown == (family == .watch))
}

/// Skipped on a watch, where the verb is supported. A `#require` would
/// fail the watch track instead.
@Test(.enabled(if: !bootedDeviceIsWatch()))
func aCrownOnANonWatchIsRefusedBeforeTheBridge() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed: the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim: run via `make test-live`"
    )
    let coordinator = PaneCoordinator()
    let result = try await coordinator.createSim(
        sessionId: UUID(),
        udid: booted.udid
    )
    await #expect(throws: PaneError.unsupportedOperation(paneId: result.paneId, operation: .crown)) {
        try await coordinator.crown(paneId: result.paneId, as: .guiPeer, delta: 30, durationMs: 0)
    }
    // Nothing reached SimulatorKit, so a client built afterwards still
    // connects and sends. After a crown event to a non-watch it would not.
    let client = try SimHIDClient.client(forUDID: booted.udid)
    let center = CGPoint(x: 0.5, y: 0.5)
    try client.tapDown(at: center)
    try client.tapUp(at: center)
}

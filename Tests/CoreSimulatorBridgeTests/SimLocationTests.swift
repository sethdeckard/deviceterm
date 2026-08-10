// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import Testing

/// Gate on probe compatibility (same model as the other bridge suites).
/// Everything that needs a *booted* sim (the real scenario list and the
/// set/scenario/clear success path) lives in the deliberate
/// `CoreSimulatorLiveTests` track; this file keeps the hermetic
/// client-construction and error paths.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

// MARK: - Lookup

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func locationClientForUnknownUDIDThrows() {
    #expect(throws: (any Error).self) {
        _ = try SimLocation.client(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func locationClientForKnownUDIDPreservesUDID() throws {
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let client = try SimLocation.client(forUDID: first.udid)
    #expect(client.udid == first.udid)
}

/// A UDID differing only in case must still resolve. The lookup
/// lowercases both sides because callers can supply mixed-case UDIDs.
@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func locationClientLookupIsCaseInsensitive() throws {
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let client = try SimLocation.client(forUDID: first.udid.lowercased())
    #expect(client.udid == first.udid.lowercased())
}

// MARK: - Degraded host

@Test(.disabled(if: coreSimulatorAvailable, "only meaningful on hosts where the probe doesn't pass"))
func locationClientForUDIDThrowsGracefullyWhenProbeFails() {
    #expect(throws: (any Error).self) {
        _ = try SimLocation.client(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}

// MARK: - Route waypoint validation

/// The waypoint array is a flat list of alternating latitude/longitude
/// numbers, and the selector behind it validates nothing: an odd count
/// would pair a latitude with the next point's longitude, and a
/// non-`NSNumber` element reaches a secure-coding archiver inside
/// Apple's code. `simctl` performs the same arity check itself, which is
/// the tell that the selector does not.
///
/// Hermetic: these are rejected in the wrapper before any device is
/// touched, so they need no booted sim. The live track covers the
/// accepted path.
///
/// Only arity is exercised from here. The element-class guard is
/// unreachable through this Swift signature, which is already
/// `[NSNumber]`; it defends the Obj-C surface, where the parameter is a
/// bare `NSArray`.
@Test(
    .disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"),
    arguments: [
        // Fewer than two waypoints.
        [],
        [1.0, 2.0],
        // A longitude with no latitude to pair with.
        [1.0, 2.0, 3.0],
        [1.0, 2.0, 3.0, 4.0, 5.0]
    ] as [[Double]]
)
func startRouteRejectsMalformedWaypoints(values: [Double]) throws {
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let client = try SimLocation.client(forUDID: first.udid)
    let waypoints = values.map { NSNumber(value: $0) }
    // Rejected identically by both modes: the check is on the array, not
    // on the cadence.
    #expect(rejectionReason { try client.startRoute(interval: 1, speed: 20, waypoints: waypoints) })
    #expect(rejectionReason { try client.startRoute(distance: 10, speed: 20, waypoints: waypoints) })
}

/// Whether the failure came from **this wrapper's** arity check rather
/// than from the device.
///
/// Asserting only "it threw" would pass for the wrong reason: the
/// devices this hermetic suite can reach are shut down, so the private
/// selector fails on its own whatever it is handed, and the guard could
/// be deleted with every case still green. The wrapper's own wording is
/// the discriminator, since nothing below it produces these sentences.
private func rejectionReason(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch {
        let message = (error as NSError).localizedDescription
        return message.contains("at least two waypoints")
            || message.contains("longitude for every latitude")
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Simulated GPS position for one physically-connected device.
///
/// The physical-device location surface, factored out of
/// `RealDeviceBackend` so the backend's dispatch can be tested without a
/// connected iPhone.
///
/// The production conformer (`DeviceCtlLocation`) shells out to
/// `xcrun devicectl device simulate location`. Everything is keyed by
/// `deviceId`, the CoreDevice identifier consumed by `--device`. The tool
/// is stateless, and the conformer keeps no per-device state.
protocol DeviceLocationSimulating: Sendable {
    /// Pin the device to a fixed coordinate until cleared.
    func setCoordinate(deviceId: String, latitude: Double, longitude: Double) async throws
    /// Start a named scenario from `availableScenarios`.
    func setScenario(deviceId: String, name: String) async throws
    /// Walk the device along a caller-supplied route.
    func startRoute(deviceId: String, spec: RouteSpec) async throws
    /// Stop any running scenario or route and drop the simulated
    /// position.
    func clear(deviceId: String) async throws
    /// The scenarios this device offers.
    func availableScenarios(deviceId: String) async throws -> [String]
}

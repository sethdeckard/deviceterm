// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Waits for a selected device's OS tunnel to come up and pins it to a concrete
/// `utun` link, yielding a `DeviceRoute`.
///
/// The resolver neither enumerates devices nor spawns a subprocess. It is handed
/// two seams:
///
/// - an **address source** that reports the device's advertised tunnel address
///   once the OS considers the tunnel connected (nil while it is still down);
///   the daemon backs this with `devicectl`, keeping subprocess ownership out of
///   this target.
/// - an **interface source** that captures the live tunnel census (defaults to a
///   real `getifaddrs` sweep).
///
/// Each attempt asks where the device claims to be, then looks for a link with
/// that far-end address in a fresh snapshot. Requiring the advertised address
/// and a live interface to agree is what makes the match authoritative when
/// several devices are connected at once.
///
/// Resolution returns on the first agreeing snapshot, so the resolver makes no
/// claim about a route that later disappears. That surfaces downstream as a
/// channel-bootstrap failure, not here.
package struct DeviceRouteResolver: Sendable {
    /// Reports `deviceId`'s advertised tunnel address, or nil while the tunnel
    /// is still down.
    package typealias AddressSource = @Sendable (_ deviceId: String) async -> String?
    /// Captures the current tunnel census.
    package typealias InterfaceSource = @Sendable () -> ReachabilitySnapshot

    private let advertisedAddress: AddressSource
    private let census: InterfaceSource

    package init(
        addressSource: @escaping AddressSource,
        interfaceSource: @escaping InterfaceSource = { .capture() }
    ) {
        self.advertisedAddress = addressSource
        self.census = interfaceSource
    }

    /// Poll until the device's advertised address matches a live `utun`, or
    /// throw `tunnelUnavailable` once the window is spent. The defaults give the
    /// tunnel ~10s to establish (25 × 400ms).
    package func resolve(
        deviceId: String,
        attempts: Int = 25,
        interval: Duration = .milliseconds(400)
    ) async throws -> DeviceRoute {
        for attempt in 0..<attempts {
            // Surface cancellation as `CancellationError`, not as a tunnel
            // timeout, including on the final attempt, which has no `Task.sleep`
            // to throw. Checked around the (non-throwing) address lookup.
            try Task.checkCancellation()
            if let advertised = await advertisedAddress(deviceId),
                let link = census().links.first(where: { $0.deviceAddress == advertised }) {
                // The address source may await a non-cancellation-aware task, so a
                // match can surface after cancellation; don't return a route for a
                // cancelled resolve.
                try Task.checkCancellation()
                return DeviceRoute(
                    deviceId: deviceId,
                    interfaceName: link.interfaceName,
                    hostAddress: link.hostAddress,
                    deviceAddress: link.deviceAddress
                )
            }
            if attempt < attempts - 1 {
                try await Task.sleep(for: interval)
            }
        }
        try Task.checkCancellation()
        throw DeviceReachabilityError.tunnelUnavailable(deviceId: deviceId)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DeviceReachability
import Foundation

/// Why channel bootstrap couldn't complete.
package enum ChannelBrokerError: Error, Sendable, Equatable {
    /// No open port answered the directory handshake, so either the device is
    /// locked or the tunnel isn't serving its directory.
    case directoryUnavailable
    /// A channel was requested for a role the device doesn't vend.
    case roleUnavailable(ChannelRole)
}

/// Turns a resolved `DeviceRoute` into the device's usable set of channels.
///
/// The tunnel serves the service directory on a dynamic port, so bootstrap
/// sweeps the device's open ports and handshake-probes them concurrently; the
/// first that answers with a services map is the directory. That single
/// handshake yields every service's port plus the device identity, which is
/// enough to open any role on demand.
package enum ChannelBroker {
    /// Discover the device's directory over `route` and return its channels.
    package static func bootstrap(route: DeviceRoute) async throws -> DeviceChannels {
        let ports = await PortSweep.openPorts(on: route.deviceAddress)
        // Surface cancellation as `CancellationError`, not as a directory failure:
        // a cancelled attach must not read as "device isn't serving its directory".
        try Task.checkCancellation()
        guard let channels = await probeForDirectory(route.deviceAddress, ports) else {
            try Task.checkCancellation()
            throw ChannelBrokerError.directoryUnavailable
        }
        // A handshake can succeed even after cancellation (the probe's socket ops
        // aren't cancellation-aware); don't hand back channels for a cancelled
        // attach.
        try Task.checkCancellation()
        return channels
    }

    /// Concurrent first-match handshake probe over `ports`. The directory is one
    /// specific port among many; probing each serially with a handshake and
    /// timeout would be too slow, so a bounded task window races them and the
    /// first success cancels the rest.
    private static func probeForDirectory(_ address: String, _ ports: [UInt16]) async -> DeviceChannels? {
        await withTaskGroup(of: DeviceChannels?.self) { group in
            let window = 16
            var next = 0
            while next < ports.count, next < window, !Task.isCancelled {
                let port = ports[next]
                group.addTask { await handshakeDirectory(address, port) }
                next += 1
            }
            while let result = await group.next() {
                if let channels = result {
                    group.cancelAll()
                    return channels
                }
                // Stop scheduling once cancelled so a cancelled attach doesn't keep
                // probing; the outer `bootstrap` surfaces the `CancellationError`.
                if next < ports.count, !Task.isCancelled {
                    let port = ports[next]
                    group.addTask { await handshakeDirectory(address, port) }
                    next += 1
                }
            }
            return nil
        }
    }

    /// Handshake one port and parse a directory from a reply that carries a
    /// services map. Any other reply or a failure means it isn't the directory.
    private static func handshakeDirectory(_ address: String, _ port: UInt16) async -> DeviceChannels? {
        let channel = DeviceChannel(host: address, port: port, readTimeout: 3)
        defer { channel.close() }
        do {
            try await channel.connect(timeout: 1)
            return parseDirectory(try await channel.requestServiceDirectory(), deviceAddress: address)
        } catch {
            return nil
        }
    }

    /// Read the services map and device identity out of a directory reply, or
    /// nil when it carries no services (so it isn't the directory endpoint).
    static func parseDirectory(_ reply: DeviceObject, deviceAddress: String) -> DeviceChannels? {
        guard case let .fields(serviceEntries)? = reply["Services"], !serviceEntries.isEmpty else {
            return nil
        }
        var byIdentifier: [String: UInt16] = [:]
        for entry in serviceEntries {
            if let port = portNumber(entry.value["Port"]) {
                byIdentifier[entry.name] = port
            }
        }
        // Keep only the services that back a role deviceterm knows; the service
        // identifiers never leave this target.
        var ports: [ChannelRole: UInt16] = [:]
        for role in ChannelRole.allCases {
            if let port = byIdentifier[role.serviceIdentifier] { ports[role] = port }
        }
        let properties = reply["Properties"]
        let identity = DeviceIdentity(
            uniqueDeviceID: properties?["UniqueDeviceID"]?.text,
            productType: properties?["ProductType"]?.text,
            osVersion: properties?["OSVersion"]?.text,
            marketingName: properties?["ProductTypeDescForUserVisibility"]?.text
        )
        return DeviceChannels(deviceAddress: deviceAddress, ports: ports, identity: identity)
    }

    /// Coerce a directory `Port` to `UInt16` however it was encoded. Observed as
    /// a string on the device, but numeric fields are commonly integers, so
    /// accept text / unsigned / signed rather than silently emptying the map on
    /// a different encoding.
    private static func portNumber(_ value: DeviceObject?) -> UInt16? {
        guard let value else { return nil }
        if let text = value.text, let port = UInt16(text) { return port }
        if let unsigned = value.unsigned { return UInt16(exactly: unsigned) }
        if let signed = value.signed { return UInt16(exactly: signed) }
        return nil
    }
}

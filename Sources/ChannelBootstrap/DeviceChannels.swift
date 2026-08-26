// SPDX-License-Identifier: GPL-3.0-or-later
/// The set of services a device vends, resolved once from its directory, plus
/// the ability to open a fresh channel to any of them by role.
///
/// Bootstrapped by `ChannelBroker`, it answers two questions the daemon asks:
/// whether a role is available (`supports`) and how to get a live channel to an
/// available one (`open` / `openIfAvailable`). Service identifiers are converted
/// to role keys during bootstrap, so this value stores none; callers only name
/// roles.
package struct DeviceChannels: Sendable {
    package let identity: DeviceIdentity

    private let deviceAddress: String
    private let ports: [ChannelRole: UInt16]

    /// Build from the roles a device vends, each mapped to its port. Callers name
    /// roles, never device-service identifiers.
    package init(deviceAddress: String, ports: [ChannelRole: UInt16], identity: DeviceIdentity) {
        self.deviceAddress = deviceAddress
        self.ports = ports
        self.identity = identity
    }

    /// Whether the device vends the service backing `role`.
    package func supports(_ role: ChannelRole) -> Bool {
        ports[role] != nil
    }

    /// Open a fresh channel for `role`, throwing if the device doesn't vend it
    /// or the connection can't be established.
    package func open(_ role: ChannelRole) async throws -> DeviceChannel {
        guard let port = ports[role] else {
            throw ChannelBrokerError.roleUnavailable(role)
        }
        let channel = DeviceChannel(host: deviceAddress, port: port, readTimeout: 10)
        do {
            try await channel.connect()
        } catch {
            channel.close()
            throw error
        }
        return channel
    }

    /// Best-effort `open`: nil when the role is absent or the connection fails,
    /// so an optional capability just stays disabled.
    package func openIfAvailable(_ role: ChannelRole) async -> DeviceChannel? {
        guard supports(role) else { return nil }
        return try? await open(role)
    }
}

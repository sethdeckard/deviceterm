// SPDX-License-Identifier: GPL-3.0-or-later
//
// PhysicalDeviceCoordinator: the daemon actor that enumerates
// physically-connected iPhones/iPads and resolves one to a streaming
// `RealDeviceBackend` on attach, holding the CoreDevice tunnel up on its
// own (no external device-management app or Xcode required).
//
// Kept separate from the CoreSimulator-bound `DeviceCoordinator`: this
// one owns the physical-device tunnel surface, not CoreSimulator handles.
//
// **Enumeration** (`enumerate`, for the picker and `devices.list`) goes
// through `devicectl list devices` (`DeviceCtl`): usbmux/lockdown, works
// with the tunnel **down**, and yields the device's real **UDID**, name,
// and model. So a device is selectable the moment it's plugged in and
// trusted; the tunnel is brought up lazily only on attach.
//
// **Attach** (`resolveBackend`) brings the tunnel up itself:
//   1. `keepalive.retain(udid)` spawns a benign blocking `devicectl`
//      subprocess that holds the RSD session (see `TunnelKeepalive`).
//   2. Hand a `devicectl`-backed address source to `DeviceRouteResolver`,
//      which polls until that UDID reports `tunnelState == connected` with a
//      `tunnelIPAddress` and matches it to the live `utun`, authoritative
//      even with several devices connected.
//   3. Bootstrap the device's channels, gate on the mirror and human-input
//      roles, and wire the mirror feed + interaction relay into the backend.
// On any failure after retain, the keepalive is released so we don't hold
// a tunnel for a pane that never mounted. The pane's eventual close
// releases it via `releaseKeepalive` (see `PaneCoordinator.close`).

import ChannelBootstrap
import DaemonProtocol
import DeviceReachability
import Foundation
import InteractionRelay
import MirrorPipeline
import os

public actor PhysicalDeviceCoordinator {
    /// Lists connected physical devices. Defaults to `devicectl`; injectable
    /// so hermetic tests provide a fixed roster without shelling out.
    typealias DeviceLister = @Sendable () async -> [DeviceCtlDevice]

    private let keepalive: TunnelKeepalive
    private let listDevices: DeviceLister

    /// Production: enumerate via `devicectl`, bring tunnels up via the
    /// keepalive. Used by the daemon's composition root (cross-module).
    public init(keepalive: TunnelKeepalive = TunnelKeepalive()) {
        self.keepalive = keepalive
        self.listDevices = { await DeviceCtl.listPhysicalDevices() }
    }

    /// Hermetic tests: inject the device roster (and optionally the keepalive)
    /// so enumeration runs without a real device or `devicectl`.
    init(
        keepalive: TunnelKeepalive = TunnelKeepalive(),
        listDevices: @escaping DeviceLister
    ) {
        self.keepalive = keepalive
        self.listDevices = listDevices
    }

    /// Connected physical devices for the picker / roster. Cheap usbmux
    /// enumeration: works with the tunnel down, returns empty when nothing
    /// is plugged in / trusted.
    public func enumerate() async -> [PhysicalDeviceInfo] {
        await listDevices().map(PhysicalDeviceInfo.init(from:))
    }

    /// Resolve a `devicectl --device <id>` spec (name | UDID | ECID, as the
    /// user typed it) to a connected device's `deviceId` handle, or nil when
    /// no connected device matches and the host has more than one candidate.
    /// Backs the shim's contextual auto-attach; resolution policy is in
    /// `DeviceSpecResolver`.
    func resolveDeviceId(forSpec spec: String) async -> String? {
        DeviceSpecResolver.resolve(spec: spec, devices: await enumerate())
    }

    /// Release the tunnel keepalive for `deviceId` (one unit of interest).
    /// Called when a device pane closes; the tunnel drops once the last
    /// mirror of the device releases.
    func releaseKeepalive(deviceId: String) {
        keepalive.release(udid: deviceId)
    }

    /// Resolve `deviceId` (a UDID) to a live `RealDeviceBackend`: bring the
    /// tunnel up via the keepalive, resolve its `DeviceRoute`, bootstrap the
    /// device's channels, gate on the mirror and human-input roles, and construct
    /// the `MirrorPipeline` feed plus the `InteractionRelay`. **Live**: only runs
    /// with the device present. An unknown UDID throws `notConnected` *before*
    /// spawning anything.
    func resolveBackend(deviceId: String) async throws -> RealDeviceBackend {
        guard await listDevices().contains(where: { $0.udid == deviceId }) else {
            throw PhysicalDeviceError.notConnected(deviceId: deviceId)
        }
        keepalive.retain(udid: deviceId)
        do {
            return try await buildBackend(deviceId: deviceId)
        } catch {
            keepalive.release(udid: deviceId)
            throw error
        }
    }

    /// Bring the device's tunnel up to a resolved `DeviceRoute`, or throw
    /// `tunnelBringUpFailed` after the poll window. `DeviceRouteResolver` is fed
    /// a `devicectl`-backed address source (the device's advertised
    /// `tunnelIPAddress`, surfaced only once the roster reports it connected)
    /// and matches it to the live `utun`, correct even with several devices
    /// connected. `DeviceCtl` (the subprocess) stays owned here.
    func resolveRoute(
        deviceId: String,
        attempts: Int = 25,
        interval: Duration = .milliseconds(400)
    ) async throws -> DeviceRoute {
        let resolver = DeviceRouteResolver(addressSource: { [listDevices] id in
            guard let device = await listDevices().first(where: { $0.udid == id }),
                device.tunnelState == "connected" else { return nil }
            return device.tunnelIPAddress
        })
        do {
            return try await resolver.resolve(deviceId: deviceId, attempts: attempts, interval: interval)
        } catch is DeviceReachabilityError {
            throw PhysicalDeviceError.tunnelBringUpFailed(deviceId: deviceId)
        }
        // Any other error (notably `CancellationError` from a cancelled attach)
        // propagates unchanged; only a reachability failure is a tunnel failure.
    }

    /// The live route→channels→backend build, factored out so `resolveBackend`
    /// can release the keepalive on any failure in here. Bootstrap the device's
    /// channels once, gate on the required roles, and wire the mirror feed and
    /// the interaction relay. No Apple service name appears here, only roles.
    private func buildBackend(deviceId: String) async throws -> RealDeviceBackend {
        let route = try await resolveRoute(deviceId: deviceId)
        let channels: DeviceChannels
        do {
            channels = try await ChannelBroker.bootstrap(route: route)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PhysicalDeviceError.serviceCatalogUnavailable(deviceId: deviceId)
        }
        // Mirror is the capability that decides whether this iOS can be mirrored
        // at all; human input is the minimum for a usable pane.
        guard channels.supports(.mirror) else {
            throw PhysicalDeviceError.tooOldToMirror(deviceId: deviceId)
        }
        guard channels.supports(.humanInput) else {
            throw PhysicalDeviceError.missingService(deviceId: deviceId, service: ChannelRole.humanInput.description)
        }
        // Route the pipeline/relay diagnostics (decoder path, decode errors,
        // keyboard recovery) to os_log so `log stream` can observe them; this
        // helper's stderr isn't otherwise visible.
        let diagnose: @Sendable (String) -> Void = { message in
            Logger(subsystem: "com.deviceterm.daemon", category: "mirror").debug("\(message, privacy: .public)")
        }
        let feed = MirrorPipeline(route: route, channels: channels, diagnostics: diagnose)
        let relay: InteractionRelay
        do {
            relay = try await InteractionRelay.make(channels: channels, diagnostics: diagnose)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The human-input service was advertised but its channel couldn't be
            // established, so treat it like an unreadable service directory.
            throw PhysicalDeviceError.serviceCatalogUnavailable(deviceId: deviceId)
        }
        // The channel operations above aren't all cancellation-aware, so a
        // cancelled attach can reach here having succeeded. Don't hand back a
        // backend for a request that was cancelled, which would carry the
        // cancelled work into pane creation. The relay/feed are released here, and
        // `resolveBackend` releases the keepalive on the throw.
        try Task.checkCancellation()
        return RealDeviceBackend(
            deviceId: deviceId,
            feed: feed,
            device: relay,
            diagnostics: diagnose
        )
    }
}

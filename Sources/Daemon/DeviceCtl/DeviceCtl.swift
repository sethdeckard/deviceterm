// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Thin wrapper around `xcrun devicectl list devices`, the
/// usbmux/lockdown enumeration that works **without** an RSD tunnel up.
///
/// This is the roster source for physically-connected devices: unlike a
/// `getifaddrs` tunnel sweep (which sees nothing until some trusted client
/// has already brought a tunnel up), `devicectl list` reaches the device
/// over usbmux and returns its **real UDID**, name, model, and, when a
/// tunnel *is* up, the device's tunnel IP. The daemon uses it both to
/// populate the picker (tunnel-down, the common case) and, during attach,
/// to read the `tunnelIPAddress` that correlates a UDID to the `utun`
/// interface its keepalive just brought up (`TunnelKeepalive`).
///
/// Parsing is split from the subprocess so the JSON decode is pure and
/// unit-tested against a fixture; `listPhysicalDevices()` runs the tool and
/// is degraded-mode tolerant: any failure (tool missing, non-zero exit,
/// malformed JSON) yields an empty roster rather than throwing, so "no
/// devices" and "couldn't tell" are one answer to the caller.
enum DeviceCtl {
    // MARK: - Decoded payload

    // The `devicectl list devices --json-output` payload, keeping only the
    // fields the daemon needs. Siblings rather than a nested chain, so the
    // deepest of them sits one level inside `DeviceCtl` and the whole shape
    // stays within the 2-level type-nesting limit. Pure: `DeviceCtl.parse`
    // is fixture-tested.
    private struct Output: Decodable {
        let result: ListResult
    }

    private struct ListResult: Decodable {
        let devices: [RawDevice]
    }

    private struct RawDevice: Decodable {
        let identifier: String
        let deviceProperties: DeviceProperties?
        let hardwareProperties: HardwareProperties?
        let connectionProperties: ConnectionProperties?
    }

    private struct DeviceProperties: Decodable {
        let name: String?
        let osVersionNumber: String?
    }

    private struct HardwareProperties: Decodable {
        let reality: String?
        let productType: String?
        let marketingName: String?
    }

    private struct ConnectionProperties: Decodable {
        let transportType: String?
        let tunnelState: String?
        let tunnelIPAddress: String?
    }

    private static let processQueue = BlockingWorkQueue(
        label: "com.deviceterm.daemon.devicectl-list"
    )

    /// Parse a `devicectl list devices --json-output` payload into the
    /// physically-connected devices (`reality == "physical"`), dropping
    /// simulators. Pure and total. Throws only on a structurally-invalid
    /// payload (not valid devicectl JSON).
    static func parse(_ data: Data) throws -> [DeviceCtlDevice] {
        let output = try JSONDecoder().decode(Output.self, from: data)
        return output.result.devices.compactMap { device in
            guard device.hardwareProperties?.reality == "physical" else { return nil }
            let hardware = device.hardwareProperties
            return DeviceCtlDevice(
                udid: device.identifier,
                name: device.deviceProperties?.name,
                model: hardware?.marketingName ?? hardware?.productType,
                osVersion: device.deviceProperties?.osVersionNumber,
                transportType: device.connectionProperties?.transportType,
                tunnelState: device.connectionProperties?.tunnelState,
                tunnelIPAddress: device.connectionProperties?.tunnelIPAddress
            )
        }
    }

    /// Run `xcrun devicectl list devices` and return the physical devices.
    /// Degraded-mode tolerant: returns `[]` on any failure (tool missing,
    /// non-zero exit, unreadable/garbled JSON) so the picker simply shows
    /// no devices rather than the RPC erroring.
    static func listPhysicalDevices() async -> [DeviceCtlDevice] {
        await processQueue.run {
            let jsonPath = NSTemporaryDirectory()
                + "deviceterm-devicectl-\(ProcessInfo.processInfo.processIdentifier)-"
                + UUID().uuidString + ".json"
            defer { try? FileManager.default.removeItem(atPath: jsonPath) }
            let process = Process()
            process.launchPath = "/usr/bin/xcrun"
            process.arguments = ["devicectl", "list", "devices", "--json-output", jsonPath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return []
            }
            guard process.terminationStatus == 0,
                let data = FileManager.default.contents(atPath: jsonPath),
                let devices = try? parse(data)
            else { return [] }
            return devices
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceSpecResolver: map a `devicectl --device <id>` spec to a
// connected device's daemon handle (`deviceId`).
//
// The shim's contextual auto-attach forwards the user's `--device`
// argument verbatim: it may be a device name, a UDID, or an ECID,
// whichever the user typed. `deviceId` is the device's real UDID, the
// same id `devicectl --device` takes, so a UDID spec matches by
// identity; a name or ECID spec does not. Resolution is deliberately
// conservative:
//
//   1. Exact handle match: the spec already *is* a known `deviceId`.
//      Covers a UDID spec and a re-attach from our own roster.
//   2. Name match, when enumeration populated a device name.
//   3. Sole connected device, the common case: one iPhone plugged in.
//      The devicectl command was explicit about a device, and there is
//      only one candidate, so attaching it is unambiguous.
//
// With two-or-more connected devices and a spec that matches none of
// them by handle or name (an ECID, say) resolution returns nil: the
// daemon will not guess which physical device the user meant, so a
// multi-device host simply doesn't auto-attach on an unmatchable spec.
//
// Pure and total, unit-tested against stub device lists with no live
// tunnel.

enum DeviceSpecResolver {
    static func resolve(spec: String, devices: [PhysicalDeviceInfo]) -> String? {
        if let exact = devices.first(where: { $0.deviceId == spec }) {
            return exact.deviceId
        }
        if let named = devices.first(where: { $0.name == spec }) {
            return named.deviceId
        }
        if devices.count == 1 {
            return devices[0].deviceId
        }
        return nil
    }
}

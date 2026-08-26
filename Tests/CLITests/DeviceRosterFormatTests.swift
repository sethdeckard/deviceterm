// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

/// `devices list` rendering: physical devices show model + OS columns
/// (disambiguating two devices that share a name); sims show `-` for
/// both. The JSON mode carries the same fields on the wire.
struct DeviceRosterFormatTests {
    @Test
    func humanFormatShowsModelAndOSForDevicesAndDashesForSims() {
        let rows = formatDeviceRoster([
            DeviceRosterEntry(
                id: "dev-a",
                kind: .device,
                name: "enceladus",
                model: "iPhone 15 Pro",
                osVersion: "17.5",
                state: "connected"
            ),
            DeviceRosterEntry(
                id: "sim-1",
                kind: .sim,
                name: "iPhone 17 Pro",
                state: "Booted"
            )
        ]).split(separator: "\n").map(String.init)

        let deviceCols = rows[0].split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        // id, kind, name, model, os, state, attachment
        #expect(deviceCols == [
            "dev-a", "device", "enceladus", "iPhone 15 Pro", "17.5",
            "connected", "available"
        ])

        let simCols = rows[1].split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(simCols == [
            "sim-1", "sim", "iPhone 17 Pro", "-", "-", "Booted", "available"
        ])
    }

    @Test
    func jsonModeCarriesModelAndOS() throws {
        let entry = DeviceRosterEntry(
            id: "dev-a",
            kind: .device,
            name: "enceladus",
            model: "iPhone 15 Pro",
            osVersion: "17.5",
            state: "connected"
        )
        let data = try JSONEncoder().encode(entry)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["model"] as? String == "iPhone 15 Pro")
        #expect(object?["osVersion"] as? String == "17.5")
    }
}

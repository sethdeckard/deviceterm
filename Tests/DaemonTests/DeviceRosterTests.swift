// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// The aggregate `devices.list` roster. The opacity logic lives in the
// pure `DeviceRoster.build`, so these cover it deterministically
// without a device or CoreSimulator; the handler tests then prove the
// thin wiring on a fresh daemon (no owned sims, no panes), which is
// robust whether or not a physical device happens to be connected.

private func ownership(_ key: String, _ session: UUID) -> PaneOwnership {
    PaneOwnership(target: .sim(udid: key), sessionId: session, paneShortId: "sh\(key)", paneId: UUID())
}

/// A **physical-device** ownership. The roster keys on kind + id, so a
/// device entry only annotates against a `.device` ownership. Using the
/// `.sim` helper above for a physical device would read as unattached
/// regardless of the opacity rule under test.
private func deviceOwnership(_ deviceId: String, _ session: UUID) -> PaneOwnership {
    PaneOwnership(
        target: .device(deviceId: deviceId),
        sessionId: session,
        paneShortId: "sh\(deviceId)",
        paneId: UUID()
    )
}

@Test
func rosterAnnotatesOwnerVisibleToCaller() {
    let owner = UUID()
    let roster = DeviceRoster.build(
        sims: [DeviceRoster.SimEntry(udid: "udid-1", name: "iPhone 17", state: "Booted")],
        physical: [],
        ownerships: [ownership("udid-1", owner)],
        visibleSessionIds: [owner]
    )
    #expect(roster.count == 1)
    #expect(roster[0].id == "udid-1")
    #expect(roster[0].kind == .sim)
    #expect(roster[0].attached)
    #expect(roster[0].ownerSessionId == owner.uuidString)
}

@Test
func rosterHidesOwnerInPrivateSessionViaOpacity() {
    let hiddenOwner = UUID()
    // The caller can't see `hiddenOwner` (a private session it doesn't
    // own), so the device must read as unattached, exactly the
    // tabs.list opacity rule.
    let roster = DeviceRoster.build(
        sims: [],
        physical: [PhysicalDeviceInfo(deviceId: "fd00::1")],
        ownerships: [deviceOwnership("fd00::1", hiddenOwner)],
        visibleSessionIds: []
    )
    #expect(roster.count == 1)
    #expect(roster[0].kind == .device)
    #expect(!roster[0].attached)
    #expect(roster[0].ownerSessionId == nil)
}

@Test
func rosterMatchesSimOwnershipCaseInsensitively() {
    // CoreSimulator hands sim UDIDs back uppercase; the pane's
    // ownership target key is the daemon's lowercase canonical form. An
    // attached sim must still annotate (and report its id in the
    // canonical lowercase that matches panes.list).
    let owner = UUID()
    let upper = "ABCD1234-5678-90AB-CDEF-1234567890AB"
    let roster = DeviceRoster.build(
        sims: [DeviceRoster.SimEntry(udid: upper, name: "iPhone 17", state: "Booted")],
        physical: [],
        ownerships: [ownership(upper.lowercased(), owner)],
        visibleSessionIds: [owner]
    )
    #expect(roster.count == 1)
    #expect(roster[0].id == upper.lowercased())
    #expect(roster[0].attached)
    #expect(roster[0].ownerSessionId == owner.uuidString)
}

@Test
func rosterMarksUnownedDevicesAvailable() {
    let roster = DeviceRoster.build(
        sims: [DeviceRoster.SimEntry(udid: "udid-2", name: "iPad", state: "Booted")],
        physical: [],
        ownerships: [],
        visibleSessionIds: [UUID()]
    )
    #expect(!roster[0].attached)
    #expect(roster[0].ownerSessionId == nil)
}

@Test
func rosterSortsById() {
    let roster = DeviceRoster.build(
        sims: [
            DeviceRoster.SimEntry(udid: "ccc", name: "c", state: "Booted"),
            DeviceRoster.SimEntry(udid: "aaa", name: "a", state: "Booted")
        ],
        physical: [PhysicalDeviceInfo(deviceId: "bbb")],
        ownerships: [],
        visibleSessionIds: []
    )
    #expect(roster.map(\.id) == ["aaa", "bbb", "ccc"])
}

@Test
func rosterCarriesModelAndOSForPhysicalDevicesOnly() {
    // Two devices that share a name are disambiguated by model + OS;
    // sims carry neither.
    let roster = DeviceRoster.build(
        sims: [DeviceRoster.SimEntry(udid: "sim-1", name: "iPhone 17", state: "Booted")],
        physical: [
            PhysicalDeviceInfo(
                deviceId: "dev-a",
                name: "enceladus",
                model: "iPhone 15 Pro",
                osVersion: "17.5"
            ),
            PhysicalDeviceInfo(
                deviceId: "dev-b",
                name: "enceladus",
                model: "iPhone 16",
                osVersion: "18.1"
            )
        ],
        ownerships: [],
        visibleSessionIds: []
    )
    let byId = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, $0) })
    #expect(byId["dev-a"]?.model == "iPhone 15 Pro")
    #expect(byId["dev-a"]?.osVersion == "17.5")
    #expect(byId["dev-b"]?.model == "iPhone 16")
    #expect(byId["dev-b"]?.osVersion == "18.1")
    // Sim leaves both nil.
    #expect(byId["sim-1"]?.model == nil)
    #expect(byId["sim-1"]?.osVersion == nil)
}

@Test
func physicalDeviceListDecodesAsArray() async throws {
    // Inject an empty device roster so the handler is hermetic: it never
    // shells out to `devicectl`; we only prove the wire shape decodes.
    let handler = PhysicalDeviceMethods.list(
        coordinator: PhysicalDeviceCoordinator(listDevices: { [] })
    )
    let data = try await handler(Data())
    _ = try JSONDecoder().decode([PhysicalDeviceListEntry].self, from: data)
}

@Test
func physicalDeviceListCarriesModelAndOS() async throws {
    // The picker entry surfaces model + OS so two devices that share a
    // name are distinguishable. Both thread from the injected
    // devicectl roster through the handler.
    let handler = PhysicalDeviceMethods.list(
        coordinator: PhysicalDeviceCoordinator(listDevices: {
            [
                DeviceCtlDevice(
                    udid: "dev-a",
                    name: "enceladus",
                    model: "iPhone 15 Pro",
                    osVersion: "17.5",
                    transportType: nil,
                    tunnelState: nil,
                    tunnelIPAddress: nil
                )
            ]
        })
    )
    let data = try await handler(Data())
    let entries = try JSONDecoder().decode([PhysicalDeviceListEntry].self, from: data)
    #expect(entries.count == 1)
    #expect(entries.first?.model == "iPhone 15 Pro")
    #expect(entries.first?.osVersion == "17.5")
}

@Test
func devicesListOnFreshDaemonHasNoSimsAndNoAttachments() async throws {
    // Fresh coordinators with an injected empty physical roster: no owned
    // booted sims, no panes, no devices. Deterministic and hermetic: the
    // roster is empty, so the all-device/all-unattached invariants hold
    // vacuously without shelling out to `devicectl`.
    let handler = PhysicalDeviceMethods.devicesList(
        deviceCoordinator: DeviceCoordinator(),
        physicalDeviceCoordinator: PhysicalDeviceCoordinator(listDevices: { [] }),
        paneCoordinator: PaneCoordinator(),
        sessionManager: SessionManager()
    )
    let data = try await handler(Data())
    let roster = try JSONDecoder().decode([DeviceRosterEntry].self, from: data)
    #expect(roster.allSatisfy { $0.kind == .device })
    #expect(roster.allSatisfy { !$0.attached })
}

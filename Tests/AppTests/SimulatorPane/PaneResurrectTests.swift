// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// The watch that re-attaches a mirrored pane whose device came back.
///
/// For a sim, both sides of the match name the same device in different
/// spellings: a watch is registered with a mounted pane's UDID, which is the
/// daemon's canonical lowercase, while the booted set comes from
/// `device.list`, which reports CoreSimulator's uppercase verbatim.
///
/// A physical device answers to a different list, and the two kinds must not
/// resolve each other: they are separate enumerations that happen to be
/// compared against one keyspace.
@MainActor
struct PaneResurrectTests {
    private static let canonical = "1d464fbe-56ba-4a49-8d73-277a7e8a0e92"
    private static let uppercased = "1D464FBE-56BA-4A49-8D73-277A7E8A0E92"

    private func booted(_ udid: String) -> DeviceListEntry {
        DeviceListEntry(
            udid: udid,
            name: "iPhone 17 Pro",
            state: "Booted",
            ownedBySession: nil
        )
    }

    private func connected(_ deviceId: String) -> PhysicalDeviceListEntry {
        PhysicalDeviceListEntry(
            deviceId: deviceId,
            name: "iPhone",
            model: nil,
            osVersion: nil,
            available: true,
            unavailableReason: nil
        )
    }

    @Test
    func aBootedSimResolvesAWatchSpelledInTheOtherCase() async {
        let fake = FakeDaemonClient()
        fake.deviceListResult = [booted(Self.uppercased)]
        let resurrect = PaneResurrect(daemonClient: fake)
        var fired = 0
        resurrect.watch(target: .sim(udid: Self.canonical), displayName: "iPhone") { fired += 1 }
        await resurrect.tick()
        #expect(fired == 1)
    }

    @Test
    func aShutdownSimLeavesItsWatchInPlace() async {
        // The negative side of the same comparison: matching case-insensitively
        // must not also stop distinguishing states.
        let fake = FakeDaemonClient()
        fake.deviceListResult = [
            DeviceListEntry(
                udid: Self.uppercased,
                name: "iPhone 17 Pro",
                state: "Shutdown",
                ownedBySession: nil
            )
        ]
        let resurrect = PaneResurrect(daemonClient: fake)
        var fired = 0
        resurrect.watch(target: .sim(udid: Self.canonical), displayName: "iPhone") { fired += 1 }
        await resurrect.tick()
        #expect(fired == 0)
    }

    @Test
    func unwatchClearsAWatchRegisteredInTheOtherCase() async {
        // `unwatch` is called from several sites, and the UDID each has in
        // hand is not always the one the watch was registered with.
        let fake = FakeDaemonClient()
        fake.deviceListResult = [booted(Self.canonical)]
        let resurrect = PaneResurrect(daemonClient: fake)
        var fired = 0
        resurrect.watch(target: .sim(udid: Self.canonical), displayName: "iPhone") { fired += 1 }
        resurrect.unwatch(target: .sim(udid: Self.uppercased))
        await resurrect.tick()
        #expect(fired == 0)
    }

    @Test
    func aReconnectedDeviceResolvesItsWatch() async {
        // Enumerable again is the whole test for a device: `physicalDevice.list`
        // reports what is connected, and mirror capability is judged at attach.
        let fake = FakeDaemonClient()
        fake.physicalDeviceListResult = [connected("D-1")]
        let resurrect = PaneResurrect(daemonClient: fake)
        var fired = 0
        resurrect.watch(target: .device(deviceId: "D-1"), displayName: "iPhone") { fired += 1 }
        await resurrect.tick()
        #expect(fired == 1)
    }

    @Test
    func aStillAbsentDeviceKeepsItsWatch() async {
        let fake = FakeDaemonClient()
        fake.physicalDeviceListResult = [connected("D-other")]
        let resurrect = PaneResurrect(daemonClient: fake)
        var fired = 0
        resurrect.watch(target: .device(deviceId: "D-1"), displayName: "iPhone") { fired += 1 }
        await resurrect.tick()
        #expect(fired == 0)
    }

    @Test
    func eachKindResolvesOnlyFromItsOwnList() async {
        // The two enumerations share a keyspace, so a device whose id matches a
        // booted sim's UDID (or the reverse) must not satisfy the other's watch.
        let fake = FakeDaemonClient()
        fake.deviceListResult = [booted(Self.canonical)]
        fake.physicalDeviceListResult = [connected("D-1")]
        let resurrect = PaneResurrect(daemonClient: fake)
        var firedSim = 0
        var firedDevice = 0
        resurrect.watch(target: .sim(udid: "D-1"), displayName: "sim") { firedSim += 1 }
        resurrect.watch(
            target: .device(deviceId: Self.canonical),
            displayName: "device"
        ) { firedDevice += 1 }
        await resurrect.tick()
        #expect(firedSim == 0)
        #expect(firedDevice == 0)
    }

    @Test
    func aSimOnlyWatchNeverEnumeratesDevices() async {
        // The poll runs every couple of seconds for as long as a watch is
        // live, so each list is queried only while a watch of that kind is
        // live rather than on every tick.
        let fake = FakeDaemonClient()
        fake.deviceListResult = [booted(Self.canonical)]
        let resurrect = PaneResurrect(daemonClient: fake)
        resurrect.watch(target: .sim(udid: Self.canonical), displayName: "iPhone") {}
        await resurrect.tick()
        #expect(fake.physicalDeviceListCallCount == 0)
    }
}

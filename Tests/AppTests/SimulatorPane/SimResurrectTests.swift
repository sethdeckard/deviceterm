// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// The watch that re-attaches a sim pane whose device came back.
///
/// Both sides of its match name the same device in different spellings: a
/// watch is registered with a mounted pane's UDID, which is the daemon's
/// canonical lowercase, while the booted set comes from `device.list`, which
/// reports CoreSimulator's uppercase verbatim.
@MainActor
struct SimResurrectTests {
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

    @Test
    func aBootedSimResolvesAWatchSpelledInTheOtherCase() async {
        let fake = FakeDaemonClient()
        fake.deviceListResult = [booted(Self.uppercased)]
        let resurrect = SimResurrect(daemonClient: fake)
        var fired = 0
        resurrect.watch(udid: Self.canonical, displayName: "iPhone") { fired += 1 }
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
        let resurrect = SimResurrect(daemonClient: fake)
        var fired = 0
        resurrect.watch(udid: Self.canonical, displayName: "iPhone") { fired += 1 }
        await resurrect.tick()
        #expect(fired == 0)
    }

    @Test
    func unwatchClearsAWatchRegisteredInTheOtherCase() async {
        // `unwatch` is called from several sites, and the UDID each has in
        // hand is not always the one the watch was registered with.
        let fake = FakeDaemonClient()
        fake.deviceListResult = [booted(Self.canonical)]
        let resurrect = SimResurrect(daemonClient: fake)
        var fired = 0
        resurrect.watch(udid: Self.canonical, displayName: "iPhone") { fired += 1 }
        resurrect.unwatch(udid: Self.uppercased)
        await resurrect.tick()
        #expect(fired == 0)
    }
}

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

    // MARK: - Repeat resurrections of one target

    @Test
    func aSecondResurrectOfOneTargetWaitsOutTheCooldown() async {
        // A sim that comes back and shuts down again on its own would
        // otherwise re-attach on every poll for as long as it keeps doing it.
        let sim = ThrashingSim()
        sim.arm()
        await sim.resurrect.tick()
        #expect(sim.fires == 1)
        // Back again in the same instant: still watched, deliberately not
        // resurrected.
        sim.arm()
        await sim.resurrect.tick()
        #expect(sim.fires == 1)
        sim.clock = 2_000_000_000
        await sim.resurrect.tick()
        #expect(sim.fires == 2)
    }

    @Test
    func theCooldownDoublesWithEachRepeat() async {
        let sim = ThrashingSim()
        sim.arm()
        await sim.resurrect.tick()
        sim.clock = 2_000_000_000
        sim.arm()
        await sim.resurrect.tick()
        #expect(sim.fires == 2)
        // The third wait is four seconds, not another two.
        sim.clock += 2_000_000_000
        sim.arm()
        await sim.resurrect.tick()
        #expect(sim.fires == 2)
        sim.clock += 2_000_000_000
        await sim.resurrect.tick()
        #expect(sim.fires == 3)
    }

    @Test
    func aTargetThatKeepsComingBackIsHandedToTheUser() async {
        // The budget is what ends the loop. Suspending this fixture's only
        // watch leaves nothing to poll for, so the daemon stops being asked.
        let sim = ThrashingSim()
        await sim.spendTheBudget()
        sim.clock += sim.nextWait
        sim.arm()
        await sim.resurrect.tick()
        #expect(sim.fires == PaneResurrect.maximumAutomaticResurrects)
        let asked = sim.fake.deviceListCalls.count
        await sim.resurrect.tick()
        #expect(sim.fake.deviceListCalls.count == asked)
    }

    @Test
    func aSuspendedWatchIsNotRevivedByExpiringHistory() async {
        // Expiring history refreshes a budget whose watch is still running. It
        // clears a suspended target's record too, but nothing moves that watch
        // back, so the target stays with the user until Reboot.
        let sim = ThrashingSim()
        await sim.spendTheBudget()
        sim.clock += sim.nextWait
        sim.arm()
        await sim.resurrect.tick()
        sim.clock += PaneResurrect.historyLifetimeNanoseconds
        await sim.resurrect.tick()
        #expect(sim.fires == PaneResurrect.maximumAutomaticResurrects)
    }

    @Test
    func expiredHistoryEarnsATargetAFreshBudget() async {
        // The counter is about thrashing, so it can't accumulate across two
        // minutes of nothing happening. A watch still running when its history
        // expires starts over.
        let sim = ThrashingSim()
        await sim.spendTheBudget()
        sim.clock += PaneResurrect.historyLifetimeNanoseconds
        sim.arm()
        await sim.resurrect.tick()
        #expect(sim.fires == PaneResurrect.maximumAutomaticResurrects + 1)
    }

    @Test
    func rebootingByHandRearmsTheTarget() async {
        // Reboot is the affordance the spent budget leaves in front of the
        // user, so it has to put the watch back as well as clear the count.
        // Nothing re-registers it: the pane is already `.shutdown`, so the
        // transition that installed the watch has long since fired. Reboot
        // also names the sim in whatever spelling its caller holds.
        let sim = ThrashingSim()
        await sim.spendTheBudget()
        sim.clock += sim.nextWait
        sim.arm()
        await sim.resurrect.tick()
        #expect(sim.fires == PaneResurrect.maximumAutomaticResurrects)  // suspended
        sim.resurrect.rearm(target: .sim(udid: Self.uppercased))
        await sim.resurrect.tick()
        #expect(sim.fires == PaneResurrect.maximumAutomaticResurrects + 1)
    }

    @Test
    func closingASuspendedPaneForgetsItsWatch() async {
        // Close Pane is the other way out of the overlay. A suspended watch it
        // left behind would resurrect a pane the user closed if the same sim
        // were ever re-attached and rebooted.
        let sim = ThrashingSim()
        await sim.spendTheBudget()
        sim.clock += sim.nextWait
        sim.arm()
        await sim.resurrect.tick()
        sim.resurrect.unwatch(target: .sim(udid: Self.uppercased))
        sim.resurrect.rearm(target: .sim(udid: Self.canonical))
        await sim.resurrect.tick()
        #expect(sim.fires == PaneResurrect.maximumAutomaticResurrects)
    }

    @Test
    func aDeviceThatKeepsComingBackIsNeverSuspended() async {
        // A device's shutdown overlay offers Close Pane alone, so suspending
        // its watch would strand the pane behind "Reconnecting…" with nothing
        // polling and no way to ask again. The cooldown still spaces it.
        let device = ThrashingSim(kind: .device)
        await device.spendTheBudget()
        device.clock += device.nextWait
        device.arm()
        await device.resurrect.tick()
        #expect(device.fires == PaneResurrect.maximumAutomaticResurrects + 1)
    }
}

/// One target that keeps coming back, with the clock the cooldown reads and
/// the tally its resurrect closure bumps. A reference type so the closure and
/// the clock seam can share it without capturing a `var`.
@MainActor
private final class ThrashingSim {
    enum Kind {
        case sim
        case device
    }

    private static let udid = "1d464fbe-56ba-4a49-8d73-277a7e8a0e92"
    private static let deviceId = "D-1"

    let fake = FakeDaemonClient()
    var clock: UInt64 = 0
    private(set) var fires = 0
    /// The cooldown the next repeat has to wait out, tracked alongside the
    /// fires that produced it.
    private(set) var nextWait: UInt64 = 0
    private let target: PaneTarget
    private var pane: PaneResurrect?

    var resurrect: PaneResurrect {
        guard let pane else {
            preconditionFailure("the fixture builds its resurrect in init")
        }
        return pane
    }

    init(kind: Kind = .sim) {
        switch kind {
        case .sim:
            target = .sim(udid: Self.udid)
            fake.deviceListResult = [
                DeviceListEntry(
                    udid: Self.udid,
                    name: "iPhone 17 Pro",
                    state: "Booted",
                    ownedBySession: nil
                )
            ]

        case .device:
            target = .device(deviceId: Self.deviceId)
            fake.physicalDeviceListResult = [
                PhysicalDeviceListEntry(
                    deviceId: Self.deviceId,
                    name: "iPhone",
                    model: nil,
                    osVersion: nil,
                    available: true,
                    unavailableReason: nil
                )
            ]
        }
        pane = PaneResurrect(daemonClient: fake, now: { [weak self] in
            self?.clock ?? 0
        })
    }

    func arm() {
        resurrect.watch(target: target, displayName: "iPhone") { [weak self] in
            self?.fires += 1
        }
    }

    /// Drive the target through its whole automatic budget, waiting out each
    /// cooldown exactly, and leave the clock at the last resurrection.
    func spendTheBudget() async {
        for _ in 0 ..< PaneResurrect.maximumAutomaticResurrects {
            clock += nextWait
            arm()
            await resurrect.tick()
            nextWait = max(nextWait * 2, 2_000_000_000)
        }
        #expect(fires == PaneResurrect.maximumAutomaticResurrects)
    }
}

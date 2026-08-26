// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

private enum DiscoveryTestError: Error {
    case unavailable
}

/// One daemon-wide read feeds every tab.
/// Failed reads publish nothing, and overlapping cadence attempts do not start
/// another read.
@MainActor
struct OwnedSimDiscoveryCoordinatorTests {
    @Test
    func oneReadFansOutToEveryObserver() async {
        let daemon = FakeDaemonClient()
        let roster = OwnedSimRoster()
        let coordinator = OwnedSimDiscoveryCoordinator(
            daemon: daemon,
            ownedSims: roster,
            automaticallyPoll: false
        )
        let entry = DeviceListEntry(
            udid: "SIM-1",
            name: "iPhone",
            state: "Booted",
            ownedBySession: "SESSION-1"
        )
        daemon.deviceListResult = [entry]
        var deliveries = [0, 0, 0]
        let tokens = deliveries.indices.map { index in
            coordinator.addObserver { entries in
                if entries == [entry] { deliveries[index] += 1 }
            }
        }

        await coordinator.pollOnceForTesting()

        #expect(daemon.deviceListCalls.map(\.scope) == [.owned])
        #expect(deliveries == [1, 1, 1])
        withExtendedLifetime(tokens) {}
    }

    @Test
    func failedReadPublishesNothingAndReleasesTheNextCadence() async {
        let daemon = FakeDaemonClient()
        let roster = OwnedSimRoster()
        let coordinator = OwnedSimDiscoveryCoordinator(
            daemon: daemon,
            ownedSims: roster,
            automaticallyPoll: false
        )
        var deliveries = 0
        let token = coordinator.addObserver { _ in deliveries += 1 }
        daemon.deviceListError = DiscoveryTestError.unavailable

        await coordinator.pollOnceForTesting()
        #expect(deliveries == 0)

        daemon.deviceListError = nil
        await coordinator.pollOnceForTesting()
        #expect(deliveries == 1)
        #expect(daemon.deviceListCalls.count == 2)
        withExtendedLifetime(token) {}
    }

    @Test
    func overlappingCadenceDoesNotStartASecondRead() async {
        let daemon = FakeDaemonClient()
        let coordinator = OwnedSimDiscoveryCoordinator(
            daemon: daemon,
            ownedSims: OwnedSimRoster(),
            automaticallyPoll: false
        )
        let token = coordinator.addObserver { _ in }
        daemon.armDeviceListBarrier()
        let first = Task { @MainActor in
            await coordinator.pollOnceForTesting()
        }
        for _ in 0..<2_000 where daemon.deviceListCalls.isEmpty {
            await Task.yield()
        }
        #expect(daemon.deviceListCalls.count == 1)

        await coordinator.pollOnceForTesting()
        #expect(daemon.deviceListCalls.count == 1)

        daemon.releaseDeviceList()
        await first.value
        withExtendedLifetime(token) {}
    }

    @Test
    func noObserversMeansNoHealthPoll() async {
        let daemon = FakeDaemonClient()
        let coordinator = OwnedSimDiscoveryCoordinator(
            daemon: daemon,
            ownedSims: OwnedSimRoster(),
            automaticallyPoll: false
        )

        await coordinator.pollOnceForTesting()

        #expect(daemon.deviceListCalls.isEmpty)
    }
}

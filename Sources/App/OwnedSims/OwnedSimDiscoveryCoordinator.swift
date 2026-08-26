// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// One app-wide owned-simulator poll whose
/// successful snapshots fan out to every live tab.
@MainActor
final class OwnedSimDiscoveryCoordinator {
    typealias Observer = @MainActor ([DeviceListEntry]) -> Void

    private let daemon: any DeviceControlling
    private let ownedSims: OwnedSimRoster
    private let intervalNanoseconds: UInt64
    private let automaticallyPoll: Bool
    private var observers: [OwnedSimDiscoveryObserverToken: Observer] = [:]
    private var pollTask: Task<Void, Never>?
    private var pollInFlight = false
    private var isShutdown = false

    init(
        daemon: any DeviceControlling,
        ownedSims: OwnedSimRoster,
        intervalNanoseconds: UInt64 = 2_000_000_000,
        automaticallyPoll: Bool = true
    ) {
        self.daemon = daemon
        self.ownedSims = ownedSims
        self.intervalNanoseconds = intervalNanoseconds
        self.automaticallyPoll = automaticallyPoll
    }

    func addObserver(_ observer: @escaping Observer) -> OwnedSimDiscoveryObserverToken {
        let token = OwnedSimDiscoveryObserverToken(id: UUID())
        observers[token] = observer
        startPollingIfNeeded()
        return token
    }

    func removeObserver(_ token: OwnedSimDiscoveryObserverToken) {
        observers.removeValue(forKey: token)
        guard observers.isEmpty else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func shutdown() {
        isShutdown = true
        pollTask?.cancel()
        pollTask = nil
        observers.removeAll()
    }

    /// Test seam for driving one cadence without a wall-clock sleep.
    func pollOnceForTesting() async {
        await pollOnce()
    }

    private func startPollingIfNeeded() {
        guard automaticallyPoll, !isShutdown, pollTask == nil, !observers.isEmpty else { return }
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self.intervalNanoseconds)
                } catch {
                    return
                }
                await self.pollOnce()
            }
        }
    }

    private func pollOnce() async {
        guard !isShutdown, !observers.isEmpty, !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }

        // The token orders this snapshot against ownership mutations that can
        // land while the daemon call is in flight. A failed read is not an
        // empty roster and never reaches either the mirror or observers.
        guard let token = ownedSims.beginRead() else { return }
        defer { ownedSims.endRead(token) }
        guard let read = try? await daemon.deviceListWithGeneration(scope: .owned)
        else { return }
        guard !Task.isCancelled, !isShutdown, !observers.isEmpty else { return }

        ownedSims.record(read.entries, generation: read.generation, read: token)
        let snapshotObservers = Array(observers.values)
        for observer in snapshotObservers {
            observer(read.entries)
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Auto-resurrect for mirrored panes that went `.shutdown`.
///
/// A pane loses its device two ways: a sim shuts down (via the pane's
/// "Reboot" button or an external `xcrun simctl shutdown`), or a
/// physically-connected device stops mirroring, most often by being unplugged,
/// locked, or losing its tunnel. Either way the GUI should re-attach in place
/// once the device is available again, keeping the user's tab layout instead
/// of leaving a dimmed overlay or spawning a new pane elsewhere.
///
/// Implemented via a bounded poll over the existing list RPCs: while at least
/// one watch is active, we ask the daemon what is available every couple of
/// seconds and resurrect any watched target that has come back. Which list
/// answers that depends on the target: a sim is back when `device.list`
/// reports it Booted, a physical device when `physicalDevice.list` enumerates
/// it again. Each list is queried only while a watch of that kind is live.
/// One instance serves the whole app, so the kinds are counted across every
/// tab and window, not per tab.
///
/// Watches are registered the moment a pane reports `.shutdown`, by
/// `SimPaneActionCoordinator` for a sim and `TabContentViewController` for a
/// device, and removed when the user clicks Close Pane or the resurrect fires.
///
/// REFACTOR: the name predates physical-device panes. `PaneResurrect` would
/// say what this watches now.
@MainActor
final class SimResurrect {
    /// Poll cadence while at least one watch is active. 2s is frequent enough
    /// that a manual reboot feels live. Polling stops entirely once no watch
    /// remains, so this runs only while a pane is waiting on its device.
    private static let pollIntervalNs: UInt64 = 2_000_000_000

    private let daemonClient: any DeviceControlling & PhysicalDeviceControlling
    private var watches: [PaneTarget: WatchEntry] = [:]
    private var pollTask: Task<Void, Never>?

    init(daemonClient: any DeviceControlling & PhysicalDeviceControlling) {
        self.daemonClient = daemonClient
    }

    /// Fold a target to one spelling before keying or comparing on it. A sim
    /// watch carries a mounted pane's daemon-canonical lowercase, while
    /// `tick`'s booted set comes from `device.list`, which reports
    /// CoreSimulator's uppercase verbatim. A `deviceId` is left alone: it has
    /// one spelling, and every other device comparison in the GUI is exact.
    private static func watchKey(_ target: PaneTarget) -> PaneTarget {
        switch target {
        case let .sim(udid):
            return .sim(udid: udid.lowercased())

        case .device:
            return target
        }
    }

    private static func isSim(_ target: PaneTarget) -> Bool {
        if case .sim = target { return true }
        return false
    }

    /// Watch `target` for its device coming back; on detection invoke
    /// `resurrect` (an in-place re-attach) and remove the watch.
    /// Re-registering the same target replaces the prior closure (the most
    /// recent owner wins).
    func watch(
        target: PaneTarget,
        displayName: String,
        resurrect: @escaping @MainActor () -> Void
    ) {
        watches[Self.watchKey(target)] = WatchEntry(
            displayName: displayName,
            resurrect: resurrect
        )
        startPollIfNeeded()
    }

    /// Stop watching `target`. Called when the user picks Close Pane
    /// on the shutdown overlay or when the resurrect fires.
    func unwatch(target: PaneTarget) {
        watches.removeValue(forKey: Self.watchKey(target))
        if watches.isEmpty { stopPoll() }
    }

    /// One sample of what the daemon can see. Resolves every watched target
    /// that is back by invoking its `resurrect` closure and removing the
    /// watch.
    ///
    /// Sims are queried at `scope:"all"` (not "owned") because the daemon
    /// released ownership at shutdown: a sim booted outside this session
    /// (Simulator.app, plain `xcrun simctl boot`, an unattributed
    /// `device.boot`) would otherwise never appear and the pane would stay
    /// stuck on its shutdown overlay.
    ///
    /// Appearing in `physicalDevice.list` is the whole test for a device.
    /// That enumeration says a device is connected, not that it can be
    /// mirrored, which is judged at attach: a device that comes back unable
    /// to mirror surfaces its error through the placeholder's Retry rather
    /// than being held back here.
    ///
    /// Public for tests; called by `pollTask` on the bounded cadence.
    func tick() async {
        var back: Set<PaneTarget> = []
        if watches.keys.contains(where: Self.isSim) {
            let all = (try? await daemonClient.deviceList(scope: .all)) ?? []
            for entry in all where entry.state == "Booted" {
                back.insert(Self.watchKey(.sim(udid: entry.udid)))
            }
        }
        if watches.keys.contains(where: { !Self.isSim($0) }) {
            let connected = (try? await daemonClient.physicalDeviceList()) ?? []
            for entry in connected {
                back.insert(Self.watchKey(.device(deviceId: entry.deviceId)))
            }
        }
        let resolved = watches.filter { back.contains($0.key) }
        for (target, entry) in resolved {
            watches.removeValue(forKey: target)
            entry.resurrect()
        }
        if watches.isEmpty { stopPoll() }
    }

    private func startPollIfNeeded() {
        guard pollTask == nil, !watches.isEmpty else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, !self.watches.isEmpty {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNs)
                await self.tick()
            }
        }
    }

    private func stopPoll() {
        pollTask?.cancel()
        pollTask = nil
    }
}

private extension SimResurrect {
    struct WatchEntry {
        let displayName: String
        let resurrect: @MainActor () -> Void
    }
}

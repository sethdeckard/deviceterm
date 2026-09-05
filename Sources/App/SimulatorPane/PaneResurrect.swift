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
/// A target that comes back and dies again immediately would otherwise
/// re-attach on every poll for as long as the condition lasts, so repeat
/// resurrections of one target are spaced by a growing cooldown.
///
/// A sim additionally stops after a few, its watch suspended rather than
/// dropped. A suspended sim is resurrected again only once `rearm` restores
/// that watch or a fresh registration replaces it. Expiring history clears
/// what the target spent but never moves a suspended watch back, so a target
/// handed to the user stays with them. A device is never suspended, because
/// its shutdown overlay offers Close Pane alone and a suspended one would sit
/// behind "Reconnecting…" with nothing coming to re-attach it.
@MainActor
final class PaneResurrect {
    /// Poll cadence while at least one watch is active. 2s is frequent enough
    /// that a manual reboot feels live. Polling stops entirely once no watch
    /// remains, so this runs only while a pane is waiting on its device.
    static let defaultPollIntervalNanoseconds: UInt64 = 2_000_000_000
    /// Spacing between repeat resurrections of one target, from the poll
    /// cadence up to a minute. The first resurrection is immediate, so a
    /// target that comes back once re-attaches on the first poll that sees it
    /// and only a target that keeps coming back pays.
    static let defaultCooldown = RetryPolicy(
        initialDelayNanoseconds: 2_000_000_000,
        maximumDelayNanoseconds: 60_000_000_000
    )
    /// Repeat resurrections allowed before a sim is handed back to the user.
    static let maximumAutomaticResurrects = 5
    /// How long a target's resurrection history outlives its last
    /// resurrection. Past it the target gets a fresh cooldown and budget.
    ///
    /// Elapsed time is the whole test. It does not distinguish a target that
    /// stayed up for two minutes from one that was unavailable for two
    /// minutes, and neither is the thrashing the budget exists to stop.
    static let historyLifetimeNanoseconds: UInt64 = 120_000_000_000

    private let daemonClient: any DeviceControlling & PhysicalDeviceControlling
    private let pollIntervalNanoseconds: UInt64
    private let cooldown: RetryPolicy
    private let now: @MainActor () -> UInt64
    private var watches: [PaneTarget: WatchEntry] = [:]
    /// Recent resurrections per target, outliving the watch that produced
    /// them. A pane that shuts down again re-registers its watch, so history
    /// kept alongside the watch would reset on exactly the event it exists to
    /// count.
    private var history: [PaneTarget: ResurrectHistory] = [:]
    /// Watches that spent their budget, holding the closure `rearm` puts back.
    /// Dropping the entry outright would leave Reboot with nothing to restore
    /// and the pane waiting on a resurrect that could never come.
    private var suspended: [PaneTarget: WatchEntry] = [:]
    private var pollTask: Task<Void, Never>?

    init(
        daemonClient: any DeviceControlling & PhysicalDeviceControlling,
        pollIntervalNanoseconds: UInt64 = PaneResurrect.defaultPollIntervalNanoseconds,
        cooldown: RetryPolicy = PaneResurrect.defaultCooldown,
        now: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.daemonClient = daemonClient
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.cooldown = cooldown
        self.now = now
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
        let key = Self.watchKey(target)
        // A live registration supersedes a suspended one. Reaching `.shutdown`
        // again means the pane left it and came back, so this closure is the
        // current owner's and the suspended one is stale.
        suspended.removeValue(forKey: key)
        watches[key] = WatchEntry(
            displayName: displayName,
            resurrect: resurrect
        )
        startPollIfNeeded()
    }

    /// Stop watching `target`. Called when the user picks Close Pane
    /// on the shutdown overlay or when the resurrect fires.
    ///
    /// Leaves the target's resurrection history alone. A pane that came back
    /// unwatches on `.rendering`, which is the top of the very cycle the
    /// history counts.
    func unwatch(target: PaneTarget) {
        let key = Self.watchKey(target)
        watches.removeValue(forKey: key)
        suspended.removeValue(forKey: key)
        if watches.isEmpty { stopPoll() }
    }

    /// Re-arm automatic resurrect for `target`: forget what it spent and put
    /// its suspended watch back, restarting the poll.
    ///
    /// Called when the user reboots from the shutdown overlay. An explicit ask
    /// earns a full budget whatever the automatic attempts spent. Restoring
    /// the watch has to happen here because the pane is already `.shutdown`,
    /// so the transition that would otherwise register one has fired already.
    func rearm(target: PaneTarget) {
        let key = Self.watchKey(target)
        history.removeValue(forKey: key)
        guard let entry = suspended.removeValue(forKey: key) else { return }
        watches[key] = entry
        startPollIfNeeded()
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
    /// A target that has come back is resurrected unless its own recent
    /// history says to wait or to stop: inside the cooldown it is left for a
    /// later tick, and a sim past its budget is suspended, leaving the user
    /// with the overlay's Reboot. The poll itself ends once the last watch
    /// goes, whether it fired, was suspended, or was unwatched.
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
        let sampledAt = now()
        // Expire history here rather than where it is read, so the table stays
        // bounded across every target the app has ever mirrored instead of
        // holding an entry per target until that target comes back.
        history = history.filter {
            sampledAt &- $0.value.firedAtUptimeNanoseconds < Self.historyLifetimeNanoseconds
        }
        let resolved = watches.filter { back.contains($0.key) }
        for (target, entry) in resolved {
            if let past = history[target] {
                // The budget applies only where the user has a way to ask
                // again, which is the sim overlay's Reboot.
                if Self.isSim(target), past.fires >= Self.maximumAutomaticResurrects {
                    suspended[target] = watches.removeValue(forKey: target)
                    continue
                }
                let wait = cooldown.delayNanoseconds(forAttempt: past.fires - 1)
                guard sampledAt &- past.firedAtUptimeNanoseconds >= wait else { continue }
            }
            history[target] = ResurrectHistory(
                fires: (history[target]?.fires ?? 0) + 1,
                firedAtUptimeNanoseconds: sampledAt
            )
            watches.removeValue(forKey: target)
            entry.resurrect()
        }
        if watches.isEmpty { stopPoll() }
    }

    private func startPollIfNeeded() {
        guard pollTask == nil, !watches.isEmpty else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, !self.watches.isEmpty {
                try? await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
                await self.tick()
            }
        }
    }

    private func stopPoll() {
        pollTask?.cancel()
        pollTask = nil
    }
}

private extension PaneResurrect {
    struct WatchEntry {
        let displayName: String
        let resurrect: @MainActor () -> Void
    }

    /// What automatic resurrect has already spent on one target.
    struct ResurrectHistory {
        let fires: Int
        let firedAtUptimeNanoseconds: UInt64
    }
}

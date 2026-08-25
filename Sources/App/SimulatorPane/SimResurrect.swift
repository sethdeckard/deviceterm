// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimResurrect: auto-resurrect for sim panes that went `.shutdown`.
//
// When a pane's underlying sim is shut down (either via the pane's
// "Reboot" button or via an
// external `xcrun simctl boot <udid>` after a shutdown), the GUI
// should re-attach a fresh sim pane in place, keeping the user's
// tab layout instead of leaving a dimmed overlay or spawning a new
// pane elsewhere.
//
// Implemented via a bounded poll: while at least one watch is
// active, we ask the daemon for `device.list(scope:"owned")`
// every couple of seconds and resurrect any watched UDID that's
// transitioned back to Booted. No new daemon RPC is needed; a
// dedicated `devices.subscribe` would avoid the poll but isn't
// built. Watches are registered by
// TabContentViewController the moment a sim pane reports `.shutdown` and
// removed when the user clicks Close Pane or the resurrect fires.

import Foundation

@MainActor
final class SimResurrect {
    /// Poll cadence while at least one watch is active. 2s is
    /// frequent enough that a manual reboot feels live, and cheap
    /// enough that idle GUI overhead is negligible (a tiny RPC per
    /// tick when at rest).
    private static let pollIntervalNs: UInt64 = 2_000_000_000

    private let daemonClient: any DeviceControlling
    private var watches: [String: WatchEntry] = [:]
    private var pollTask: Task<Void, Never>?

    init(daemonClient: any DeviceControlling) {
        self.daemonClient = daemonClient
    }

    /// Watch `udid` for a Booted transition; on detection invoke
    /// `resurrect` (typically a TabContentViewController re-attach) and remove
    /// the watch. Re-registering the same UDID replaces the prior
    /// closure (the most recent owner wins).
    func watch(
        udid: String,
        displayName: String,
        resurrect: @escaping @MainActor () -> Void
    ) {
        watches[udid] = WatchEntry(displayName: displayName, resurrect: resurrect)
        startPollIfNeeded()
    }

    /// Stop watching `udid`. Called when the user picks Close Pane
    /// on the shutdown overlay or when the resurrect fires.
    func unwatch(udid: String) {
        watches.removeValue(forKey: udid)
        if watches.isEmpty { stopPoll() }
    }

    /// One sample of the daemon's full booted set. Resolves every
    /// watched UDID that's now Booted by invoking its `resurrect`
    /// closure and removing the watch. We query `scope:"all"` (not
    /// "owned") because the daemon released ownership at shutdown:
    /// a sim booted outside this session (Simulator.app, plain
    /// `xcrun simctl boot`, an unattributed `device.boot`) would
    /// otherwise never appear and the pane would stay stuck on its
    /// shutdown overlay. Public for tests; called by `pollTask` on
    /// the bounded cadence.
    func tick() async {
        let all = (try? await daemonClient.deviceList(scope: .all)) ?? []
        let bootedNow = Set(
            all.filter { $0.state == "Booted" }.map(\.udid)
        )
        let resolved = watches.filter { bootedNow.contains($0.key) }
        for (udid, entry) in resolved {
            watches.removeValue(forKey: udid)
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

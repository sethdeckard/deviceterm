// SPDX-License-Identifier: GPL-3.0-or-later
//
// OwnedSimDecision: the owned-roster predicates behind the close prompts.
//
// The close flows ask different questions of the same read. Tab and window
// close filter Booted sims by the sessions they are about to close. Pane
// close starts from one udid and excludes owners live in another tab. Quit
// does not use this type at all; it acts on the whole booted roster.
//
// The predicates are pure and the read is not, so they are separated here:
// this type answers from a list already in hand, and
// `DeviceControlling+OwnedSims` does the `device.list` around it. The
// ownership rules are the part worth testing, and this way they test without
// a daemon.

import DaemonProtocol

enum OwnedSimDecision {
    /// CoreSimulator's state name for a running sim, as `device.list`
    /// relays it. `DeviceListEntry.state` is a wire string rather than an
    /// enum, so the literal lives here once instead of at each comparison.
    static let bootedState = "Booted"

    /// Sims in `devices` that are Booted and attributed to `sessions`, in
    /// the roster's own order.
    ///
    /// A `.owned` read establishes that deviceterm owns every entry, so the
    /// session filter is about attribution, not ownership: it narrows the
    /// roster to the sims these particular sessions answer for. An entry
    /// with no `ownedBySession` is owned by deviceterm but attributed to
    /// nobody, and never matches.
    static func booted(
        ownedBy sessions: Set<String>,
        in devices: [DeviceListEntry]
    ) -> [DeviceListEntry] {
        devices.filter {
            $0.state == bootedState && sessions.contains($0.ownedBySession ?? "")
        }
    }

    /// Whether `sessions` hold any Booted sim: the "is there anything to
    /// ask about" gate in front of the tab and window close prompts.
    static func anyBooted(
        ownedBy sessions: Set<String>,
        in devices: [DeviceListEntry]
    ) -> Bool {
        devices.contains {
            $0.state == bootedState && sessions.contains($0.ownedBySession ?? "")
        }
    }

    /// The `.owned` entry for `udid` if it is still Booted.
    ///
    /// Returns the entry rather than a verdict so the caller keeps the
    /// attribution and can judge it against workspace state sampled after
    /// the roster read. `isOursToStop` is that judgement.
    ///
    /// The udid is compared case-insensitively. Callers hold udids from
    /// pane state, `device.list`, and the CLI, and CoreSimulator is not
    /// consistent about case across them.
    static func bootedEntry(
        udid: String,
        in devices: [DeviceListEntry]
    ) -> DeviceListEntry? {
        devices.first {
            $0.udid.caseInsensitiveCompare(udid) == .orderedSame
                && $0.state == bootedState
        }
    }

    /// Whether a running owned sim attributed to `owner` is this pane's to
    /// offer stopping. `claimedElsewhere` is the sessions live in other tabs.
    ///
    /// Neither "attributed to my sessions" nor "attributed at all" is the
    /// right test on its own, because attribution moves in both directions:
    ///
    /// - Closing the terminal that booted a sim drops that session from the
    ///   tab and closes it daemon-side, but disowns nothing. The sim stays
    ///   owned and Booted under a session that no longer exists, with its
    ///   pane still mounted. Requiring a live session would skip the prompt
    ///   for exactly that sim and strand it running.
    /// - Booting the same udid from another tab gives that tab a live pane
    ///   while this one keeps a stale shut-down pane. The sim is now the
    ///   other tab's. Ignoring attribution would let closing the stale pane
    ///   stop a simulator someone else is using.
    ///
    /// So the test is ownership nobody else holds. An entry attributed to a
    /// dead session, to nobody, or to this tab is this pane's to ask about.
    ///
    /// Separate from the roster read because tab membership has to be
    /// sampled after that read returns: a tab opened while it was in flight
    /// would be missing from a set gathered beforehand, and its simulator
    /// would look unclaimed.
    static func isOursToStop(ownedBySession owner: String?, claimedElsewhere: Set<String>) -> Bool {
        guard let owner else { return true }
        return !claimedElsewhere.contains(owner)
    }
}

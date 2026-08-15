// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceControlling+OwnedSims: read the owned roster, then ask
// `OwnedSimDecision` about it.
//
// The close prompts need to know whether detaching would leave a sim
// running, and only the daemon knows. The read is one `device.list` and the
// judgement is pure, so the split is here: fetch once, delegate, and decide
// what a failed read means.

import DaemonProtocol

/// What a roster read said about one sim, with "the read failed" kept
/// distinct from "no".
///
/// A Bool collapses those two, and the collapse is not safe in either
/// direction. Answering `false` on a failure silently detaches a sim the
/// user would have been asked about. Answering `true` hands an unverified
/// sim to a stored `shutdown` default, which stops it without ever asking.
/// Callers have to see the difference and choose.
enum OwnedSimLookup: Equatable {
    /// In the owned roster and still Booted, carrying whatever session the
    /// daemon attributes it to. Whether that makes it this pane's to stop
    /// is the caller's call, made against workspace state sampled after
    /// this read, not folded in here.
    case running(ownedBySession: String?)
    /// Absent from the owned roster, or present and already stopped.
    case notRunning
    /// The read failed. Says nothing about the sim either way.
    case unknown
}

extension DeviceControlling {
    /// Whether any of `sessions` holds a Booted sim. True when the read
    /// fails, so tab and window close follow their configured-or-prompted
    /// disposition rather than silently forcing detach.
    ///
    /// That is not the same guarantee the pane path gets. A stored
    /// `shutdown` still short-circuits the prompt here, so a failed read can
    /// reach `pane.close(mode: .shutdown)` on a premise nothing confirmed.
    func hasOwnedBootedSims(forSessions sessions: [String]) async -> Bool {
        guard let owned = try? await deviceList(scope: .owned) else { return true }
        return OwnedSimDecision.anyBooted(ownedBy: Set(sessions), in: owned)
    }

    /// Preserves a failed read as `.unknown`, so pane close can bypass a
    /// stored decision instead of acting on one.
    func lookUpOwnedSim(udid: String) async -> OwnedSimLookup {
        guard let owned = try? await deviceList(scope: .owned) else { return .unknown }
        guard let entry = OwnedSimDecision.bootedEntry(udid: udid, in: owned) else {
            return .notRunning
        }
        return .running(ownedBySession: entry.ownedBySession)
    }
}

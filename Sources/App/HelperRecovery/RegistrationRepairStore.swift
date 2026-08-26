// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads and writes the "a repair was interrupted" marker: a record that a
/// launchd registration repair was started and did not finish, so a later
/// launch can complete it.
///
/// A value type over a path so a test can point it at a temporary directory
/// without touching the user's real Application Support.
///
/// The repair tears the agent's registration down and stands it back up. Between
/// those two legs the helper is registered nowhere, and a process that dies in
/// that window leaves the user with no helper at all, which is worse than the
/// wire mismatch the repair was treating. An in-process task cannot close that
/// gap: it survives its caller's cancellation, not the process, and every exit
/// from the surrender UI terminates the process on purpose.
///
/// So the record is on disk, and every operation here FAILS CLOSED.
///
///   - Resolving the location throws rather than falling back. A fallback path
///     would be shared rather than per-user and would sit outside the directory
///     the rest of the app's durable state lives in, so a marker written there
///     is not the guarantee it looks like. No location means no repair.
///   - Inspecting throws on anything but a clean "no such file". A lookup that
///     could not be completed must not read as "nothing to do", because that is
///     the answer which skips the reconciliation.
///   - The marker is written BEFORE the teardown begins, and a write that fails
///     aborts the repair. A teardown that outruns its marker is exactly the
///     failure this exists to prevent, so the marker is a precondition and not a
///     record of the past.
///   - A failed clear leaves the marker in place. Reconciliation is idempotent,
///     so a redundant one costs a launch a moment; a marker lost while the repair
///     was incomplete costs the user their helper.
///
/// It answers ONE question: was a repair started and not finished? It is
/// deliberately not asked to say whether one is running right now. Concurrency is
/// `RegistrationRepairLock`'s job. Production reads and writes here happen while
/// the caller holds that lock, which is why a single marker needs no owner, no
/// pid, and no liveness check. This type does not enforce that; its callers do.
///
/// A passive file cannot act as a barrier: every liveness sample has a race after
/// it, and a non-atomic write can be read half-published.
///
/// The write is still atomic, which under the lock is belt and braces rather than
/// the mechanism.
///
/// This is deliberately NOT `WelcomeSeenStore`. That one lives in the XDG cache
/// directory and swallows every failure by design, because re-showing a welcome
/// is harmless and a purged cache is expected. Both properties are disqualifying
/// here, so this lives in Application Support beside the daemon's own durable
/// state and reports its failures.
///
/// Not claimed to be power-loss safe: that needs file and directory `fsync`, and
/// the exposure is the short window between the write and the teardown. Process
/// termination and crashes, which are the cases that actually arise, are covered.
struct RegistrationRepairStore {
    private let path: String

    /// Test seam: the resolved marker location, so a test can assert where the
    /// standard store puts it without reaching into the filesystem.
    var markerPathForTesting: String { path }

    /// Where the exclusion lock for this store's repairs lives. Beside the
    /// marker, so the pair moves together.
    var lockPath: String { path + ".lock" }

    init(path: String) {
        self.path = path
    }

    private static func isNoSuchFile(_ error: NSError) -> Bool {
        guard error.domain == NSCocoaErrorDomain else { return false }
        return error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
    }

    /// `~/Library/Application Support/deviceterm/registration-repair`, beside
    /// the daemon socket the same directory already holds.
    ///
    /// Throws rather than substituting a fallback location. A caller that
    /// cannot resolve this must not start a repair at all.
    static func standard() throws -> RegistrationRepairStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return RegistrationRepairStore(
            path: support.appendingPathComponent("deviceterm/registration-repair").path
        )
    }

    /// Whether a repair was started and not finished.
    ///
    /// Only a clean "no such file" answers false. Every other failure
    /// propagates, because false is the answer that skips the reconciliation and
    /// a lookup that did not complete is not evidence for skipping it.
    func isRepairUnderway() throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return true
        } catch let error as NSError where Self.isNoSuchFile(error) {
            return false
        }
    }

    /// Record that a repair is starting. Throws rather than reporting failure in
    /// a return value, because every caller must treat a failure here as a
    /// reason not to begin.
    func markRepairUnderway() throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url, options: .atomic)
    }

    /// Record that the repair completed. Call only after the registration has
    /// been stood back up.
    func clearRepairUnderway() throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error as NSError where Self.isNoSuchFile(error) {
            return
        }
    }
}

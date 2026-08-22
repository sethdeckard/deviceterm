// SPDX-License-Identifier: GPL-3.0-or-later
//
// OwnedSimRoster: the GUI's mirror of which sims deviceterm owns, kept so
// the answer survives the helper it came from.
//
// Ownership lives in the daemon's memory alone, so a helper that restarts
// comes back believing it owns nothing. A sim carried by a pane is restored
// by re-attaching the pane. A sim the user detached has no pane to carry it,
// and this mirror is the only live, trusted record automatic warm-restart
// recovery can act on.
//
// Nothing extra is read for it. The app-wide discovery coordinator already
// asks for `device.list({scope: "owned"})` every couple of seconds and fans
// that daemon-wide answer out to every live tab. What the mirror adds is
// holding onto it across the moment the daemon forgets.
//
// The mirror is NOT the on-disk `owned-udids.json`, and deliberately can't
// become it. That file is an untrusted recovery hint a same-uid process can
// rewrite, admissible only behind the human-confirmed orphan prompt. This is
// a live read from the daemon, held in memory, discarded with the process.
//
// A GUI that just launched has an empty mirror and nothing to restore. Sims
// left running by a previous launch are the cold-start orphan prompt's
// business, not this one.

import DaemonProtocol

/// What one replacement helper needs to be told, and the connection it is
/// being told on, so a settle can name the attempt it belongs to.
struct OwnedSimRestore: Equatable {
    let generation: Int
    let claims: [RestoredSimOwnership]
}

@MainActor
final class OwnedSimRoster {
    /// Lowercased udid → owning session id, as of the last accepted read, or
    /// nil for a sim deviceterm owns with no session behind it.
    ///
    /// A key means owned; the value is only the attribution. The helper
    /// reports an Unlinked sim in the owned roster with no session, and a
    /// mirror that dropped those would erase them on the first poll after
    /// restoration put them back. Only ever read by iterating, so the double
    /// optional a subscript would produce never comes up.
    private var claims: [String: String?] = [:]
    /// The connection whose answers the mirror currently believes. A read
    /// tagged with anything else is dropped rather than merged. Nil until the
    /// first read arrives, because the transport numbers connections from one
    /// and there is nothing yet to disbelieve.
    private var trustedGeneration: Int?
    /// A replacement connection whose re-assertion hasn't run yet, or nil
    /// when the mirror is up to date with the live helper.
    private var pendingGeneration: Int?
    /// The read currently outstanding, or nil when none is. At most one at a
    /// time, which is what puts the snapshots in an order at all.
    ///
    /// The coordinator acquires this slot before each read, and roster tests
    /// use the same fence directly. Since the daemon provides no snapshot
    /// revision, only one read may be in flight.
    private var outstandingRead: Int?
    private var nextRead = 0
    /// The highest token whose answer has been taken. Tokens only ever rise,
    /// so with one read outstanding this rejects nothing on its own; what it
    /// catches is a read the mirror learned better than while it was in
    /// flight (see `noteOwned`).
    private var highestAcceptedRead = 0

    /// Whether the mirror is holding claims for a helper that hasn't been
    /// told about them yet. Diagnostic; the Router asks for the claims.
    var isAwaitingRestore: Bool { pendingGeneration != nil }

    /// Claim the roster-read slot for a request about to be issued, or nil
    /// when another read already holds it.
    ///
    /// Pair every non-nil result with `endRead`, on the failure and
    /// cancellation paths too. A token that is never released stops the mirror
    /// tracking the helper for good.
    func beginRead() -> Int? {
        guard outstandingRead == nil else { return nil }
        nextRead += 1
        outstandingRead = nextRead
        return nextRead
    }

    /// Release the read slot, whatever came of the read.
    func endRead(_ token: Int) {
        guard outstandingRead == token else { return }
        outstandingRead = nil
    }

    /// What a replacement helper needs to be told, or nil when the mirror is
    /// already up to date with the live one. Claims are sorted so a batch
    /// reads the same way twice in a log or a test.
    ///
    /// A non-nil result with no claims is not the same as nil: it means there
    /// was nothing to restore, and the caller still owes a `settle` to start
    /// believing the new helper's reads.
    func beginRestore() -> OwnedSimRestore? {
        guard let generation = pendingGeneration else { return nil }
        return OwnedSimRestore(
            generation: generation,
            claims: claims
                .map { RestoredSimOwnership(udid: $0.key, sessionId: $0.value) }
                .sorted { $0.udid < $1.udid }
        )
    }

    /// Merge one SUCCESSFUL owned-roster read, tagged with the connection it
    /// was answered on.
    ///
    /// Wholesale replacement, not a merge: at a settled generation the daemon
    /// is the authority on what deviceterm owns, and this is a cache of that
    /// answer. Which is exactly why the generation tag matters. A replacement
    /// helper answers "nothing is owned" perfectly correctly, and adopting
    /// that answer would erase the claims re-assertion exists to restore. A
    /// read from any connection but the trusted one is dropped, and only
    /// `settle()` moves that trust forward.
    ///
    /// `generation` must be captured with the response, not sampled after it
    /// (`deviceListWithGeneration`). A helper replaced while the read was in
    /// flight would otherwise be credited with the previous helper's roster,
    /// and once that generation settles the mirror believes it.
    ///
    /// `read` is the token `beginRead` handed out. Its answer is dropped when
    /// the mirror learned something newer while it was in flight.
    ///
    /// A failed read is not a fact about ownership and must not be reported
    /// here as an empty roster.
    func record(_ entries: [DeviceListEntry], generation: Int, read: Int) {
        // No roster read is accepted while a restore is owed; the claims
        // already held stay trusted. The generation check below usually covers
        // it, but only by implication, and the invariant is the point: until
        // the helper has been told what it owns, its answer describes one that
        // hasn't heard the claims yet.
        guard pendingGeneration == nil else { return }
        guard read > highestAcceptedRead else { return }
        if let trustedGeneration, generation != trustedGeneration { return }
        highestAcceptedRead = read
        trustedGeneration = generation
        claims = [:]
        // Every entry is a claim: `.owned` already establishes deviceterm's
        // ownership, so a missing `ownedBySession` says nobody is attributed
        // rather than that nobody owns it.
        //
        // State is deliberately not filtered. `.owned` already carries the
        // daemon's attribution decision, and the helper checks current Booted
        // state again before restoring it after a replacement.
        for entry in entries {
            claims[entry.udid.lowercased()] = entry.ownedBySession
        }
    }

    /// A daemon answer that established ownership: `device.attach` or a
    /// promoted boot claim. The mirror learns it without waiting for a poll.
    ///
    /// Without this the mirror's only input is a poll up to two seconds away,
    /// and a sim owned and then detached inside one interval leaves recovery
    /// nothing to act on: the pane is gone and no read ever saw it.
    /// Reboot-then-close is the same shape, since a shutdown poll clears the
    /// claim before the boot puts it back.
    ///
    /// Unlike a read, this is not gated on the generation: the caller is
    /// reporting its own completed action, not relaying a helper's answer. It
    /// does *seed* the trusted generation when there isn't one, because a
    /// mirror holding claims and believing nothing in particular will accept a
    /// replacement helper's empty roster and erase them. `generation` must be
    /// the one the call itself reported, captured with its answer; the current
    /// connection read afterward can name a replacement, and seeding to that
    /// is what lets the replacement's empty roster through.
    ///
    /// Any read already in flight may carry a snapshot older than this, since
    /// dispatch says nothing about when the helper took it, so its result is
    /// refused rather than risked against a completed action.
    func noteOwned(udid: String, sessionId: String?, generation: Int) {
        claims[udid.lowercased()] = sessionId
        if trustedGeneration == nil { trustedGeneration = generation }
        highestAcceptedRead = nextRead
    }

    /// A shutdown the GUI just made succeed. The daemon dropped its ownership
    /// record as part of it, so the mirror is wrong until it hears the same.
    ///
    /// Without this a shut-down sim keeps its claim until the next poll, and a
    /// helper that restarts first has recovery re-asserting it. A fresh helper
    /// holds no attribution to conflict with and judges the claim on current
    /// boot state alone, so another tool booting that sim in the meantime would
    /// see deviceterm claim a device it no longer owns: the one
    /// mis-attribution this whole path is built to avoid.
    ///
    /// Invalidates in-flight reads for the same reason `noteOwned` does: an
    /// outstanding read may predate the shutdown and put the claim back.
    func noteShutdown(udid: String) {
        claims.removeValue(forKey: udid.lowercased())
        highestAcceptedRead = nextRead
    }

    /// A replacement connection is live: hold the current claims for it, and
    /// stop believing reads until they have been re-asserted.
    ///
    /// Called from the reconnect hook rather than inferred from a failed
    /// read, because a helper can be replaced without any read failing: a
    /// crash between two polls is answered by the fresh helper on the next
    /// one.
    ///
    /// Compared against the window already open rather than against the
    /// trusted generation. A read from the replacement can land during its
    /// handshake, before this notification, and settle trust on that
    /// generation; measuring against trust would then read this as old news
    /// and never open a window at all.
    func connectionReplaced(generation: Int) {
        guard generation > pendingGeneration ?? 0 else { return }
        pendingGeneration = generation
    }

    /// Whether `generation`'s restore is still the one owed. A caller retrying
    /// a failed re-assertion stops once a newer connection has taken over,
    /// since that connection runs its own.
    func isRestorePending(_ generation: Int) -> Bool {
        pendingGeneration == generation
    }

    /// Re-assertion has had its turn on `generation`, whatever came of it.
    /// Start believing that connection's reads.
    ///
    /// Deliberately carries no outcome. A claim the helper refused is dropped
    /// by the next successful poll anyway, since that poll replaces the claims
    /// with the helper's own answer, and a claim the call never reached is
    /// simply absent from that helper. Staying pending instead would freeze
    /// the mirror against a helper it can no longer describe.
    ///
    /// Named rather than implicit because a second connection can arrive while
    /// the first re-assertion is still in flight. Settling whatever happens to
    /// be pending would let the older attempt close the newer one's window,
    /// and the helper behind it would never be told anything.
    func settle(generation: Int) {
        guard pendingGeneration == generation else { return }
        trustedGeneration = generation
        pendingGeneration = nil
        // Every read issued before now was answered from a snapshot of a
        // helper that had not been told what it owns yet. Taking one after
        // this point would erase the claims restoration just handed over, and
        // a second connection before the next poll would have nothing left to
        // hand over.
        highestAcceptedRead = nextRead
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The daemon's actor for session lifecycle.
///
/// Each session backs one terminal pane (a tab may hold several): it holds a
/// label, a non-recoverable verifier for the capability issued at create time
/// (never the bearer token), the kernel `owner` identity of the process that
/// created it, and the panes scoped to it. Credential-bearing methods validate
/// `(sessionId, cap)` against this manager, but the cap is
/// only ONE factor: it is readable by any same-uid process (`ps -E`), so it
/// can't by itself stop one terminal's shell from spoofing another's. The
/// connection layer additionally checks the caller's kernel provenance (owner
/// identity, or the session's bound terminal via `terminalAnchorStore`) against
/// `ProvenanceMatcher` before installing a session principal. This manager owns
/// the cap verifier + owner identity + the shared `terminalAnchorStore`; the
/// provenance decision lives in the connection layer.
///
/// Each session carries a stable `tabId` grouping/reference UUID plus a
/// `shortId` and optional `name`. These fields ride through `tabs.list` and
/// `session.create`; callers holding a list snapshot can resolve them with
/// `TabRefResolver`.
public actor SessionManager {
    /// A session id's ordered lifecycle phase, carrying its incarnation.
    private enum Phase {
        case pendingRegistration(UInt64)
        case ready(UInt64)
        case tearingDown(UInt64)
    }

    /// Why a session is being torn down. Diagnostics only, since both paths run
    /// the same teardown, but the distinction is the reason to log it. An
    /// explicit `session.close` is caller-requested (the method is
    /// `.session`-scoped, so any authenticated caller can close its own
    /// session). A reap is daemon-side reconciliation against an authoritative
    /// restore batch that omitted the session, which also revokes that
    /// session's pane subscriptions.
    private enum TeardownReason: String {
        case sessionClose = "session.close"
        case reapedByRestoreBatch = "reaped-by-restore-batch"
    }

    /// Strictly-increasing `createdAt` step for restored sessions, so a batch's
    /// entry order is preserved by the `createdAt`-sorted `tabs.list`. The
    /// one-microsecond step preserves deterministic order within the restored
    /// batch.
    private static let restoreOrderStep: TimeInterval = 0.000001

    private var sessions: [UUID: SessionState] = [:]
    /// Sessions whose tab carries the protection flag. Kept in memory for the
    /// session's lifetime; reset when a session is closed. A separate
    /// set rather than a field on `SessionState` keeps `SessionState`
    /// immutable (the documented invariant) and avoids re-keying
    /// every consumer that builds session payloads from snapshots.
    private var protectedSessions: Set<UUID> = []
    /// Live display title per session, as last pushed by the GUI. A side
    /// map for the same reason `protectedSessions` is one: `SessionState` is
    /// immutable by design and this value churns as the shell retitles.
    /// Derived state, deliberately memory-only: after a
    /// daemon restart it is empty until the GUI republishes, which is
    /// honest (nothing on disk can claim to know a live label). Absent
    /// key means "no title"; the entry is removed on a null push and with
    /// the session in `removeSessionMaps`, so a recycled short id can
    /// never surface a dead tab's title.
    private var displayTitles: [UUID: String] = [:]
    /// Connection that last wrote each session's display title. Handler
    /// tasks are not FIFO, so a push admitted on a connection the GUI has
    /// already given up on can resume *after* its replacement's push and
    /// reinstate a label the human has moved past, with nothing to correct
    /// it until the title next changes. Connection ids are assigned from a
    /// monotonic counter, so "strictly older writer" is decidable here
    /// without putting a sequence number on the wire. Keyed per session
    /// rather than daemon-wide so two GUI instances, each publishing its own
    /// sessions, can't starve each other.
    private var displayTitleWriters: [UUID: UInt64] = [:]
    /// Last-applied protection ordering key per session. The daemon is the
    /// authority for last-write-wins: a `setProtectedBatch` applies only
    /// when its `(epoch, revision)` key strictly dominates the stored key
    /// of every target session; otherwise it is stale and mutates
    /// nothing. Cleared with the session in `closeSession`. Empty for a
    /// session never touched by a batch (any key dominates), which is why
    /// `initialProtected` need not seed it. Cleared with the session in
    /// `removeSessionMaps`, which both the close path and `restoreBatch`'s
    /// ghost reconciliation run.
    private var protectionOrdering: [UUID: ProtectionOrderingKey] = [:]
    /// The ordering key that most recently asserted each session's existence.
    /// stamped by `session.create` (`.liveAuthority` tier) or by the
    /// `restoreBatch` that carried it (`.restoreBaseline` tier). `restoreBatch`
    /// is an authoritative COMPLETE inventory, and this full `(epoch, tier,
    /// revision)` key (not a bare epoch) is what its reconciliation compares:
    /// a session the daemon still holds but that a batch with a strictly-greater
    /// key OMITS is an abandoned ghost (a lost `session.close`) and is reconciled
    /// away. The tier keeps a live `session.create` on the SAME connection from
    /// being reaped by a restore that merely raced it (live authority outranks
    /// the restore baseline at one epoch), while the revision lets a
    /// same-connection retry that drops a session actually reap it (a higher
    /// restore revision dominates the earlier one that asserted it). Cleared with
    /// the session in `removeSessionMaps`.
    private var sessionAssertionKey: [UUID: ProtectionOrderingKey] = [:]
    /// Highest `(epoch, revision)` key of any `restoreBatch` applied so far. A
    /// strictly older restore key is rejected; an equal key may replay
    /// idempotently. A rejected batch (a dead/older connection's late batch, or
    /// a same-connection retry that lost the race) mutates nothing and does not
    /// release the barrier, so it can neither revert protection nor resurrect a
    /// reconciled ghost. The `revision` half is what lets same-connection
    /// retries (equal epoch) order: each carries a strictly-higher revision.
    private var lastRestorationKey: ProtectionOrderingKey?
    /// Session ids that a `restoreBatch` could resurrect: every session created
    /// by the validated GUI (`createSession`'s `restorable`) or restored (all
    /// restored sessions are GUI-supplied). ONLY these can appear in a GUI
    /// restore inventory, so ONLY their closes need a tombstone. A session minted
    /// over UDS or an unvalidated peer (an agent's own, or an attacker churning
    /// `session.create`/`.close`) is never in a GUI inventory, so it is not
    /// tracked here and its close never tombstones, which is what keeps
    /// adversarial same-uid churn from growing the tombstone set at all. Removed
    /// at close (in `removeSessionMaps`); the removal is what gates the tombstone.
    private var restorableSessions: Set<UUID> = []
    /// Tombstones for RESTORABLE sessions closed via `closeSession`, so a
    /// `restoreBatch` refuses to re-insert one: an already-captured (stale)
    /// inventory that still lists a just-closed session can't resurrect it.
    /// Session ids are unique UUIDs, so a closed id is dead for good, and the GUI
    /// legitimately retains a closing terminal until `session.close` returns (so
    /// a concurrent restore, even one still parked in XPC validation/scheduling,
    /// can still carry the id). NOT set by ghost reconciliation; a stale batch
    /// that omitted a ghost is already fenced by `lastRestorationKey`.
    ///
    /// Reclaimed only by a restore that omits the id
    /// (`reclaimTombstones`), the sole sound signal. The GUI's restore loop is
    /// serial (it awaits each reply before sending the next), so once the daemon
    /// processes a restore that omits the id, every EARLIER restore has already
    /// been processed (their replies were the loop's gate) and every LATER one is
    /// captured after the close, so none can resurrect it. A transition-count or
    /// wall-clock expiry is NOT sound: XPC dispatch is non-FIFO, so a restore
    /// listing the id can sit in validation/scheduling while later operations
    /// would expire the tombstone. The set is bounded because the GUI re-supplies
    /// its inventory on every workspace-session-set change (not just on
    /// reconnect) via `InventorySyncCoordinator`, so a closed session's tombstone
    /// is reclaimed by the next omitting inventory rather than accumulating until
    /// a reconnect.
    private var closeTombstones: Set<UUID> = []
    /// The per-session serialized transition lane. Every asynchronous lifecycle
    /// effect for an id (store revoke/register, pane-subscription sweep,
    /// `EventBroker` finish/reactivate, readiness publication, and the caller's
    /// completion) runs as one transition enqueued here and executes strictly
    /// in enqueue order for that id. The synchronous mutation segments (which
    /// keep `sessions`/`sessionPhase`/ordering keys correct) run actor-isolated
    /// and enqueue transitions in the right order; the lane then guarantees, per
    /// id, that a teardown of incarnation G completes ALL its revocation before a
    /// later registration of G+1 begins. Different ids run on independent lanes.
    /// `laneDepth` counts an id's in-flight transitions so an idle lane is
    /// reclaimed (see `finishTransition`), bounding the serializer itself.
    private var lifecycleLane: [UUID: Task<Void, Never>] = [:]
    private var laneDepth: [UUID: Int] = [:]
    /// Test-only seam: awaited once at the top of every lane transition
    /// (`runRegistration` / `runTeardown`), before it mutates any store or phase,
    /// so a test can deterministically suspend one transition and interleave
    /// another lifecycle op's synchronous segment. Always nil in production.
    var transitionEntryHook: (@Sendable () async -> Void)?
    /// Late-bound pane-subscription revoker (`PaneCoordinator.revokeSubscriptions
    /// (forSession:)`). `SessionManager` is built before `PaneCoordinator`, so
    /// this is installed during composition, mirroring `storeReconcileEntryHook`
    /// and the store wiring. `main.swift` (where process termination is
    /// permitted) asserts it is set BEFORE the RPC servers `bind`, so a closed
    /// session's live subscriptions are always torn down. The destructive
    /// finalize calls it on the close/ghost path so a session close revokes the
    /// session's pane subscriptions before the close is acknowledged. Nil only in
    /// hermetic tests that stand up no `PaneCoordinator` (there are no
    /// subscriptions to revoke); production is fail-closed by the startup assert.
    private var paneRevoker: (@Sendable (UUID) async -> Void)?
    /// Cohort-store teardown, installed alongside `paneRevoker`. Runs for every
    /// teardown reason so a reaped session cannot linger as a cohort member.
    private var cohortRevoker: (@Sendable (UUID, UInt64) async -> Void)?
    /// Awaited before a registering incarnation becomes admissible: drains the
    /// cohort effect pump, so a prior incarnation's close consequences are
    /// applied to the device layer before this one can create state a late
    /// effect would sweep. Installed by `installCohortWiring`.
    private var registrationBarrier: (@Sendable () async -> Void)?
    /// Late-bound pane-producer activation seam (`PaneCoordinator.noteSessionActive`).
    /// Called from a registration transition when a session reaches `.ready`, so
    /// the pane coordinator's local active-incarnation map, which its
    /// synchronous ownership-commit check reads, reflects the current
    /// incarnation. Paired with `paneRevoker`, which clears it on teardown.
    /// Installed during composition alongside `paneRevoker`.
    private var paneActivator: (@Sendable (UUID, UInt64) async -> Void)?
    /// Daemon-global monotonic incarnation allocator. A fresh number is minted
    /// on every session INSERT (create or restore), lives only in the id's
    /// transient lifecycle phase, and never crosses the wire. Pairing the id
    /// with its incarnation closes a reincarnation ABA hole: a request
    /// authorized under incarnation G carries G to the producers, so it can't
    /// pass a later incarnation's gate after the same UUID was closed and
    /// restored at G+1.
    private var incarnationCounter: UInt64 = 0
    /// Per-id ordered lifecycle phase (see the nested `Phase`).
    /// `.pendingRegistration(n)` means inserted but not yet registered, so it
    /// is not admissible and `.session(id)` gets retryable `notReady`.
    /// `.ready(n)` is admissible. `.tearingDown(n)` means a destructive finalize
    /// is in flight and is not admissible. The daemon-global counter
    /// allocates each `n`; the entry is DROPPED when the id settles
    /// fully-absent (no pending reinsertion), so no per-UUID map grows for the
    /// daemon's lifetime.
    private var sessionPhase: [UUID: Phase] = [:]
    /// Injected clock: tests pin `createdAt` to a fixed instant so
    /// ordering assertions don't depend on real-time scheduling.
    /// Production callers use the default (`Date.init`).
    private let now: @Sendable () -> Date
    /// Injected short_id mint strategy. Production uses
    /// `ShortID.generate()`; tests inject a deterministic sequence
    /// (e.g. forced collision-then-resolve) to exercise the retry
    /// path without depending on RNG luck.
    private let mintShortID: @Sendable () -> String
    /// Injected process-liveness check. Production uses the
    /// `kill(pid, 0)` ping (`SessionManager.processIsAlive`); tests
    /// inject a deterministic predicate so `isAlive`'s owner-liveness
    /// classification can be exercised without spawning real processes.
    private let isProcessAlive: @Sendable (pid_t) -> Bool
    /// Optional event broker. When non-nil, the manager publishes
    /// `session.created` + `session.closed` scoped to that session, so the
    /// session's own `deviceterm events` subscribers (and the GUI peer)
    /// see its lifecycle. Nil in tests that don't care about the broker.
    private let eventBroker: EventBroker?
    /// The restoration barrier. A fresh production daemon starts with this
    /// false (pending): it holds NO session from disk, and a validated GUI
    /// must re-supply its live inventory via `restoreBatch` before the daemon
    /// is "restored". While pending, the connection layer reclassifies an
    /// unknown-session `session.authenticate` from the hard `unauthorized`
    /// (-32001) to the retryable `notReady` (-32002), so an in-tab CLI/shim
    /// keeps its bounded retry instead of pruning a still-valid credential
    /// before restoration runs. Processing ANY `restoreBatch` (even an empty
    /// one) releases it permanently. Defaults to released for tests that do
    /// not exercise restoration; production opts into pending via
    /// `startsPendingRestoration`.
    private var restorationBarrierReleased: Bool
    /// The automation-grant store is a required shared dependency (defaults
    /// to a fresh empty store). Closing a session revokes its grant before the
    /// close completes, so an automation lease can never outlive the session
    /// it authorizes: the same authenticated socket fails its next
    /// automation call after close. This is the **single owner** of the grant
    /// ledger: `DaemonMethods.defaultRegistry` sources the registry's store
    /// (which both dispatchers' scope checks and the advertiser read) FROM this
    /// manager, so the ledger the handlers write, the ledger enforcement reads,
    /// and the ledger close-revocation mutates cannot diverge.
    let automationGrantStore: AutomationGrantStore
    /// The terminal-anchor store is a required shared dependency, not an
    /// optional. The manager keeps its live-session set in lockstep with
    /// `sessions` (register at create/restore, remove at close), and the
    /// SAME instance MUST back the `session.bindTerminal` handler, the
    /// connections' provenance lookup, and the XPC-close revoke path; a bind
    /// that lands in a different store than the one the lookup reads would
    /// report every session unknown. Exposed (immutable, Sendable actor, so
    /// nonisolated-accessible) precisely so `DaemonMethods.defaultRegistry`
    /// and the daemon's provenance lookup derive it from here rather than
    /// risking a mismatched second instance. Defaults to a fresh store so
    /// tests that don't exercise provenance still construct cleanly.
    nonisolated public let terminalAnchorStore: TerminalAnchorStore

    /// Diagnostic accessor: count without exposing the map.
    public var sessionCount: Int {
        sessions.count
    }

    /// Test-only: the current close-tombstone count.
    var closeTombstoneCount: Int { closeTombstones.count }

    /// Whether the pane revoker seam is installed. `main.swift` asserts this
    /// before binding the RPC servers, so a closed session's subscriptions can
    /// never be silently skipped in production.
    public var hasPaneRevoker: Bool { paneRevoker != nil }

    /// Whether the cohort revoker seam is installed, asserted the same way:
    /// without it a torn-down session would silently linger in every
    /// sibling's cohort membership.
    public var hasCohortRevoker: Bool { cohortRevoker != nil }

    /// Whether the pre-admission barrier is installed. `installCohortWiring`
    /// installs it together with the revoker and the effect sink; the wiring
    /// test asserts all three.
    public var hasRegistrationBarrier: Bool { registrationBarrier != nil }

    /// Whether the restoration barrier has been released. True once any
    /// `restoreBatch` (even empty) has been processed, or immediately for a
    /// manager not constructed `startsPendingRestoration`. The connection
    /// layer reads this to decide whether an unknown-session authenticate is
    /// retryable (`notReady`, still pending) or terminal (`unauthorized`).
    public var isRestorationComplete: Bool {
        restorationBarrierReleased
    }

    public init(
        now: @Sendable @escaping () -> Date = { Date() },
        mintShortID: @Sendable @escaping () -> String = { ShortID.generate() },
        isProcessAlive: @Sendable @escaping (pid_t) -> Bool = SessionManager.processIsAlive,
        eventBroker: EventBroker? = nil,
        startsPendingRestoration: Bool = false,
        automationGrantStore: AutomationGrantStore = AutomationGrantStore(),
        terminalAnchorStore: TerminalAnchorStore = TerminalAnchorStore()
    ) {
        self.now = now
        self.mintShortID = mintShortID
        self.isProcessAlive = isProcessAlive
        self.eventBroker = eventBroker
        self.restorationBarrierReleased = !startsPendingRestoration
        self.automationGrantStore = automationGrantStore
        self.terminalAnchorStore = terminalAnchorStore
    }

    /// The production liveness ping. `kill(pid, 0)` sends no signal; it
    /// succeeds when the process exists and we can signal it, fails with
    /// `ESRCH` when the pid is gone, and fails with `EPERM` when the
    /// process is alive under a different uid. EPERM must count as alive,
    /// since a permission denial means "running, just untouchable." Only
    /// `ESRCH` reads as dead; every other errno is treated as alive, the
    /// conservative choice for both reaping (don't drop a session we're
    /// unsure about) and orphan-adoption (don't steal one). Signal 0 is
    /// always valid, so `kill` never returns EINVAL here in practice.
    public static func processIsAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// Apply a COMPLETE, AUTHORITATIVE session inventory supplied by a
    /// validated GUI over XPC (`session.restoreBatch`), the sole path by which
    /// sessions come back after a daemon-only restart. Nothing is rehydrated
    /// from disk. The batch is an `(epoch, tier, revision)`-fenced, all-or-none
    /// transaction (`epoch` = connection id, rising across reconnects; `tier` =
    /// the `restore` tier, which sits below the `live` tier of any
    /// `session.create`/`session.setProtectedBatch` at the same epoch; `revision` =
    /// the GUI's monotonic per-send counter, rising across same-connection
    /// retries):
    ///
    /// 0. **Staleness fence.** `epoch` is the issuing connection id, monotonic
    ///    across reconnects. A restore strictly older than the last applied one
    ///    is rejected without mutating anything or releasing the barrier, so a
    ///    dead/older connection's late batch can neither revert protection nor
    ///    resurrect a reconciled ghost.
    /// 1. **Validate** the whole batch (in-batch dedup, short-id syntax,
    ///    verifier/metadata agreement for a live session, short-id collision).
    ///    Any failure throws and mutates NOTHING.
    /// 2. **Apply** in one synchronous actor segment, which also records the
    ///    key and releases the barrier up front (reserved before any
    ///    suspension, so a restore interleaving during the async tail sees it
    ///    and bails at step 0 unless it is genuinely newer): insert every ABSENT
    ///    session (protection seeded fail-closed in-turn) except one still
    ///    tombstoned from a recent `session.close`, which a stale captured
    ///    inventory must not resurrect, and for a live session
    ///    re-apply its authoritative protection under this batch's `(epoch,
    ///    .restoreBaseline, revision)` key, so a NEWER restore (even a
    ///    same-connection retry with a higher revision) corrects a stale protection
    ///    value, while a live `setProtectedBatch` the user issued after the restore
    ///    still wins (it carries the higher `.liveAuthority` tier). Immutable
    ///    metadata (tab id / role / short id) is validated to match and left untouched.
    ///    Every in-batch session's assertion key is refreshed to this batch.
    /// 3. **Reconcile removals.** The batch is the complete inventory, so a live
    ///    session it OMITS whose assertion key is strictly dominated by this
    ///    batch's key is an abandoned ghost (a lost `session.close`) and is torn
    ///    down. A session created on this same connection after the snapshot
    ///    survives (its `.liveAuthority` assertion outranks the restore baseline
    ///    at the same epoch), and a session an EARLIER same-connection retry
    ///    asserted but this one drops IS reaped (a higher revision dominates).
    /// 4. Enqueue each insert's REGISTRATION and each ghost's TEARDOWN on that
    ///    id's serial lane (`lifecycleLane`). Every asynchronous per-session
    ///    effect (grant/anchor register or revoke, pane-subscription sweep,
    ///    `EventBroker` finish/reactivate, readiness, and `.sessionCreated` /
    ///    `.sessionClosed`) runs inside its transition, so per id a teardown of
    ///    G completes ALL of G's revocation before a reinserted G+1 registers.
    ///    A restored session is anchor-less and grant-less until the GUI's
    ///    follow-up `bindTerminal` / grant.
    /// 5. Await the enqueued transitions and build the echo, which confirms
    ///    only ids that reached ready at their exact incarnation. Processing
    ///    any non-stale batch, including an empty one, releases the barrier
    ///    (in step 2).
    ///
    /// `owner` is captured server-side from the validated XPC peer (identical
    /// to `session.create`), never wire-supplied, so a restored session gets
    /// the live GUI as its owner: `isAlive` tracks the GUI, orphan adoption
    /// works, and the exact-owner XPC provenance arm authenticates it.
    ///
    /// Entry order defines `tabs.list` ordering for the restored set:
    /// inserted sessions are stamped with strictly-increasing `createdAt`
    /// values from a single base instant, so batch order is preserved within
    /// the restored set.
    @discardableResult
    public func restoreBatch(
        _ entries: [RestoreSessionEntry],
        owner: OwnerProcessIdentity?,
        epoch: UInt64,
        revision: Int
    ) async throws -> SessionRestoreBatchResult {
        // ONE key governs staleness, protection, AND membership for this batch:
        // `(epoch, .restoreBaseline, revision)`. The `.restoreBaseline` tier is
        // what keeps a reconnect restore's inventory value BELOW any live user
        // action at the same epoch: a `setProtectedBatch`/`protectionSnapshot`
        // (`.liveAuthority`) the user issues after the restore always wins, and a
        // live `session.create` membership stamp (`.liveAuthority`) is never
        // reaped by a same-connection restore that merely raced it. Within the
        // `.restoreBaseline` tier the `revision` orders same-connection retries
        // against each other, so a higher retry can both correct a present
        // session's protection and reap one an earlier retry asserted but this one
        // drops. Across reconnects the epoch (compared first) still dominates.
        let restoreKey = ProtectionOrderingKey(epoch: epoch, revision: revision, tier: .restoreBaseline)
        // 0. Staleness fence over `restoreKey`. A batch whose key does not
        //    dominate the last applied one is stale and is rejected WITHOUT
        //    mutating anything or releasing the barrier. This includes a late
        //    batch from an older connection or a superseded retry. An EQUAL key (a
        //    network-duplicated frame) is allowed and re-applies idempotently;
        //    only a strictly-older key is stale.
        if let last = lastRestorationKey, restoreKey < last {
            throw RestoreBatchError.staleBatch(epoch: epoch)
        }
        // 1. Validate the WHOLE batch before mutating anything.
        var seenIds = Set<UUID>()
        var seenShortIds = Set<String>()
        var liveShortIds: [String: UUID] = [:]
        for state in sessions.values { liveShortIds[state.shortId] = state.id }
        for entry in entries {
            guard seenIds.insert(entry.id).inserted else {
                throw RestoreBatchError.duplicateSessionId(entry.id)
            }
            guard ShortID.isWellFormed(entry.shortId) else {
                throw RestoreBatchError.malformedShortId(entry.shortId)
            }
            guard seenShortIds.insert(entry.shortId).inserted else {
                throw RestoreBatchError.duplicateShortId(entry.shortId)
            }
            if let live = sessions[entry.id] {
                // A live session must match by verifier, or a stale cap would
                // silently rebind it to new credentials.
                guard live.capabilityVerifier.matches(entry.capability) else {
                    throw RestoreBatchError.verifierConflict(entry.id)
                }
                // Same verifier but disagreeing immutable metadata (tab id /
                // short id / role): report the mismatch rather than silently rewrite it.
                guard live.shortId == entry.shortId, live.role == entry.role,
                    live.tabId == entry.tabId else {
                    throw RestoreBatchError.metadataConflict(entry.id)
                }
            } else if let holder = liveShortIds[entry.shortId], holder != entry.id {
                // A NEW session's short id must not collide with a DIFFERENT
                // live session's because short ids are immutable CLI handles.
                throw RestoreBatchError.shortIdCollision(entry.shortId)
            }
        }
        // 2. SYNCHRONOUS MUTATION SEGMENT: no interior `await`, so it is atomic
        //    against actor reentrancy and a concurrent `tabs.list`/`restoreBatch`
        //    can never observe a torn state. The key is RESERVED first, before
        //    any suspension, so a restore that interleaves during the async tail
        //    below observes it and bails (step 0) unless it is genuinely newer.
        lastRestorationKey = restoreKey
        restorationBarrierReleased = true
        let base = now()
        let batchIds = Set(entries.map(\.id))
        // Drop close tombstones for any id this inventory OMITS: the GUI's
        // authoritative view has moved past those closes, so no future restore
        // will list them. A tombstone for an id this batch still LISTS is
        // retained so the insert below skips it.
        reclaimTombstones(keeping: batchIds)
        // Registration transitions enqueued for this batch's inserts, keyed by
        // id, carrying the exact incarnation and its lane handle. Awaited (with
        // the ghost teardowns) after the synchronous segment; the restore echo
        // then confirms only those that reached ready AT their incarnation.
        var insertedRegistrations: [UUID: (incarnation: UInt64, task: Task<Void, Never>)] = [:]
        for (index, entry) in entries.enumerated() {
            if sessions[entry.id] == nil {
                // A closed session id is dead for good (UUIDs are never reused),
                // so an already-captured stale inventory that still lists it must
                // not resurrect it. Skip without inserting, registering, or
                // stamping an assertion key; it is simply not restored.
                if closeTombstones.contains(entry.id) { continue }
                let state = SessionState(
                    id: entry.id,
                    capabilityVerifier: CapabilityVerifier(for: entry.capability),
                    shortId: entry.shortId,
                    label: nil,
                    name: entry.name,
                    createdAt: base.addingTimeInterval(Double(index) * Self.restoreOrderStep),
                    role: entry.role,
                    // Owner captured from the validated XPC peer (never the
                    // wire), so the restored session is owned by the live GUI.
                    ownerPID: owner?.pid,
                    owner: owner,
                    tabId: entry.tabId
                )
                sessions[entry.id] = state
                if entry.isProtected { protectedSessions.insert(entry.id) }
                protectionOrdering[entry.id] = restoreKey
                // Allocate the incarnation and enqueue its registration on the
                // id's lane. If a predecessor teardown of this UUID is still in
                // flight, `enqueueRegistration` sets `.pendingRegistration(n+1)`
                // and the lane runs this registration STRICTLY AFTER that
                // teardown, so the reinserted incarnation registers fresh only
                // once its predecessor is fully revoked. No separate deferral
                // bookkeeping: the FIFO is the ordering.
                let incarnation = allocateIncarnation()
                let registration = enqueueRegistration(entry.id, incarnation)
                insertedRegistrations[entry.id] = (incarnation, registration)
            } else if protectionDominates(restoreKey, over: protectionOrdering[entry.id]) {
                // Present session, re-asserted by this inventory: apply its
                // authoritative protection ONLY when this key dominates the stored
                // one, so a NEWER restore (higher revision, even same
                // connection) corrects an older restore value, while a live
                // `setProtectedBatch` the user made after the restore keeps its
                // higher-tier win. Immutable metadata is validated to match, so
                // it is left untouched.
                if entry.isProtected { protectedSessions.insert(entry.id) } else { protectedSessions.remove(entry.id) }
                protectionOrdering[entry.id] = restoreKey
            }
            // Every in-batch session is re-asserted as live by this batch, so a
            // later reconciliation keeps it (and a same-connection retry that
            // drops it can reap it via the higher revision).
            sessionAssertionKey[entry.id] = restoreKey
            // Any session a validated inventory lists is GUI-supplied and thus
            // restorable: whether just inserted OR already present (a session
            // created while validation was transiently unavailable, confirmed
            // here). Marking it (not just inserts) ensures its later close leaves
            // a tombstone. Skipped-tombstone entries `continue` above and are
            // never reached here.
            restorableSessions.insert(entry.id)
        }
        // Reconcile removals: the batch is the COMPLETE inventory, so a live
        // session it OMITS whose assertion key is strictly dominated by this
        // batch's key is an abandoned ghost (a lost `session.close`) and is
        // dropped. A session created on this same connection after the snapshot
        // survives (its `.liveAuthority` assertion outranks the `.restoreBaseline`
        // at the same epoch); a session an earlier same-connection retry asserted
        // but this one drops is reaped (a higher revision dominates). Map
        // removals are synchronous here; the cross-actor store revokes run in the
        // async tail. A session with no assertion key is treated as reapable
        // (fail-closed); every live session has one, so this is defensive.
        let ghosts = sessions.keys.filter { id in
            !batchIds.contains(id) && (sessionAssertionKey[id].map { $0 < restoreKey } ?? true)
        }
        // Enqueue each ghost's teardown transition atomically with its map
        // removal (same synchronous segment). A `nil` handle means nothing to
        // tear down; a coalesced double-removal returns the in-flight teardown.
        var ghostTeardowns: [Task<Void, Never>] = []
        for id in ghosts {
            removeSessionMaps(id)
            if let teardown = enqueueTeardown(id, reason: .reapedByRestoreBatch) {
                ghostTeardowns.append(teardown)
            }
        }
        // End of the synchronous segment: the in-memory maps are now
        // consistent, and every async lifecycle effect is enqueued on its id's
        // lane in the right order.
        // Await the enqueued transitions. Each runs (per id) in enqueue order,
        // so a reinserted incarnation's registration completes only after its
        // predecessor teardown fully revoked the prior one. Awaiting order here
        // doesn't affect execution order (the lanes do); it only waits for
        // completion.
        for teardown in ghostTeardowns { await teardown.value }
        for (_, task) in insertedRegistrations.values { await task.value }
        // Report the sessions HELD AND READY after this batch (in entry order).
        // An inserted id counts only once its registration reached `.ready` AT
        // its incarnation (a reinsertion superseded by a racing removal, or one
        // still mid-teardown, is absent from the echo, so the GUI's inventory
        // check retries until it converges). An already-live re-assertion counts.
        // A tombstone-skipped id is honestly absent.
        let held = entries.filter { entry in
            guard sessions[entry.id] != nil else { return false }
            let adm = admission(for: entry.id)
            if let registration = insertedRegistrations[entry.id] {
                // A locally-inserted session counts only at its EXACT expected
                // incarnation (a racing removal that superseded it is excluded).
                return adm == .ready(incarnation: registration.incarnation)
            }
            // A re-asserted (already-present) session counts only if it currently
            // has a concrete `.ready` admission, not while another batch has it
            // mid-registration (`.notReady`), so a retry never confirms another
            // batch's pending session.
            if case let .ready(inc) = adm, inc != nil { return true }
            return false
        }
        let restoredIds = held.map(\.id.uuidString)
        return SessionRestoreBatchResult(
            restoredCount: restoredIds.count,
            sessionIds: restoredIds
        )
    }

    /// Test-only: install the transition entry hook (see `transitionEntryHook`).
    /// A method because the property is actor-isolated. No production caller.
    func setTransitionEntryHook(_ hook: @escaping @Sendable () async -> Void) {
        transitionEntryHook = hook
    }

    /// Install the pane-subscription revoker (see `paneRevoker`). Called during
    /// composition once the `PaneCoordinator` exists, before the RPC servers
    /// accept connections. A method because the property is actor-isolated.
    public func setPaneRevoker(_ revoker: @escaping @Sendable (UUID) async -> Void) {
        paneRevoker = revoker
    }

    /// Install the cohort-store teardown (see `cohortRevoker`).
    func setCohortRevoker(_ revoker: @escaping @Sendable (UUID, UInt64) async -> Void) {
        cohortRevoker = revoker
    }

    /// Install the pre-admission barrier (see `registrationBarrier`).
    func setRegistrationBarrier(_ barrier: @escaping @Sendable () async -> Void) {
        registrationBarrier = barrier
    }

    /// Install the pane-producer activation seam (see `paneActivator`) and
    /// REPLAY every currently-ready session into it. Production wires this before
    /// any session exists, so the replay is empty; but a caller (a test harness)
    /// that mints ready sessions BEFORE installing the seam would otherwise leave
    /// the pane coordinator with no active-incarnation entry for them, so a
    /// `pane.create`/`device.attach` for such a session would wrongly get
    /// `ownerNotReady`. Snapshotting AFTER the install (no `await` between) means
    /// a session that reaches ready concurrently is covered either by the
    /// snapshot or by its own registration calling the now-installed activator;
    /// a redundant activation is idempotent.
    public func setPaneActivator(_ activator: @escaping @Sendable (UUID, UInt64) async -> Void) async {
        paneActivator = activator
        let readyNow: [(UUID, UInt64)] = sessionPhase.compactMap { id, phase in
            if case let .ready(incarnation) = phase { return (id, incarnation) }
            return nil
        }
        for (id, incarnation) in readyNow {
            await activator(id, incarnation)
        }
    }

    /// Lifecycle admission for the connection layer's scope check.
    /// `.ready(incarnation:)` admits and carries the incarnation for the
    /// principal; `.notReady` blocks with the retryable code (mid-registration
    /// or mid-teardown); `.absent` is terminal. A session present in `sessions`
    /// with no phase entry is admitted un-pinned (defensive: every
    /// create/restore sets a phase).
    public func admission(for sessionId: UUID) -> SessionAdmission {
        switch sessionPhase[sessionId] {
        case let .ready(incarnation):
            return .ready(incarnation: incarnation)

        case .pendingRegistration, .tearingDown:
            return .notReady

        case nil:
            return sessions[sessionId] != nil ? .ready(incarnation: nil) : .absent
        }
    }

    /// Admission phase + captured owner for `sessionId`, read in ONE actor turn
    /// so the incarnation and the owner can't straddle a G→G+1 transition (the
    /// owner always belongs to the same incarnation the admission reports). The
    /// caller reads the terminal anchor separately and re-confirms the
    /// incarnation is unchanged afterward.
    public func provenanceSnapshot(for sessionId: UUID) -> (admission: SessionAdmission, owner: OwnerProcessIdentity?) {
        (admission(for: sessionId), sessions[sessionId]?.owner)
    }

    /// The currently-admissible incarnation of a session id, or nil if it is
    /// not `.ready`. Used to stamp a pane's accepted incarnation with the
    /// TARGET session's actual incarnation (not the calling connection's), so a
    /// validated-GUI create/adoption pins the pane to the owner's real
    /// incarnation. A production pane create REQUIRES a concrete value; a nil
    /// (not-ready) target is refused at the coordinator.
    public func incarnation(of sessionId: UUID) -> UInt64? {
        if case let .ready(value) = admission(for: sessionId) { return value }
        return nil
    }

    /// Mint the next incarnation. Called in a synchronous mutation segment, so
    /// the allocation and the phase write are one actor turn.
    private func allocateIncarnation() -> UInt64 {
        incarnationCounter &+= 1
        return incarnationCounter
    }

    // MARK: - Per-session serialized transition lane

    /// Enqueue an incarnation-scoped transition on `id`'s serial lane and return
    /// a handle the caller awaits. The transition runs only after every prior
    /// transition for this id completes, so per id the effects apply in enqueue
    /// order. Enqueuing (and the tail read/write) is synchronous and
    /// actor-isolated, so the ordering the synchronous mutation segments set up
    /// is preserved. `laneDepth` counts in-flight transitions so the lane is
    /// reclaimed once idle.
    private func enqueueTransition(
        _ id: UUID,
        _ transition: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        laneDepth[id, default: 0] += 1
        let prior = lifecycleLane[id]
        let task = Task { [weak self] in
            await prior?.value
            await transition()
            await self?.finishTransition(id)
        }
        lifecycleLane[id] = task
        return task
    }

    /// Decrement `id`'s in-flight transition count and reclaim its lane entry
    /// once idle, so the serializer can't grow without bound.
    private func finishTransition(_ id: UUID) {
        let remaining = (laneDepth[id] ?? 1) - 1
        if remaining <= 0 {
            laneDepth[id] = nil
            lifecycleLane[id] = nil
        } else {
            laneDepth[id] = remaining
        }
    }

    /// The REGISTRATION transition for `incarnation`: register the grant + anchor
    /// stores, advance the phase to `.ready`, reactivate the event stream at this
    /// incarnation, and publish `.sessionCreated`. Guarded on the id still being
    /// `.pendingRegistration(incarnation)`: a removal that superseded it (set
    /// `.tearingDown`) makes this a no-op, so a session removed before it
    /// registered never becomes ready and its teardown (next on the lane)
    /// revokes any store write this made.
    private func runRegistration(_ id: UUID, _ incarnation: UInt64) async {
        if let hook = transitionEntryHook { await hook() }
        guard case .pendingRegistration(incarnation) = sessionPhase[id] else { return }
        // Drain the cohort effect pump before this incarnation can become
        // admissible. A prior incarnation's close effects are enqueued before
        // its teardown, and the lane serializes that teardown before this
        // registration, so waiting here guarantees the device layer has
        // applied every earlier era's consequences before this session can
        // register a claim or take ownership. Without it, a close effect for
        // the same UUID could arrive late and sweep state the new incarnation
        // just created. The wait is bounded by the queue, which is empty
        // outside an in-flight close.
        await registrationBarrier?()
        guard case .pendingRegistration(incarnation) = sessionPhase[id] else { return }
        await automationGrantStore.registerSession(id)
        await terminalAnchorStore.registerSession(id)
        // Re-check after the store awaits: a removal may have superseded this
        // incarnation. If so, bail; the teardown enqueued after us revokes what
        // we just wrote.
        guard case .pendingRegistration(incarnation) = sessionPhase[id] else { return }
        // Activate BOTH producers BEFORE opening admission (phase `.ready`), so
        // no request can be admitted while the EventBroker still refuses its
        // `daemon.events` subscribe (which would ack then immediately finish the
        // stream) or while the pane producer has no active-incarnation entry
        // (which its exact-equality commit check would then reject). After both
        // installs, re-check the SAME pending incarnation still exists (a removal
        // may have superseded it), and only THEN flip to `.ready` and publish.
        await eventBroker?.reactivateSession(id, incarnation: incarnation)
        await paneActivator?(id, incarnation)
        guard case .pendingRegistration(incarnation) = sessionPhase[id], let state = sessions[id] else { return }
        sessionPhase[id] = .ready(incarnation)
        DiagnosticLog.session.info(
            "ready incarnation=\(incarnation, privacy: .public)"
        )
        await eventBroker?.publish(
            .sessionCreated(sessionId: id.uuidString, shortId: state.shortId, name: state.name),
            to: .session(id)
        )
    }

    /// The TEARDOWN transition for `incarnation`: revoke the grant + anchor
    /// stores (clearing the entries AND live-set membership), sweep the session's
    /// pane subscriptions, then atomically finish + retire its event stream (the
    /// final `.sessionClosed`). Because the lane serializes, a teardown of G
    /// completes ALL of this before a later registration of G+1 runs, so G+1
    /// never inherits G's grant/anchor and never publishes/readies before G is
    /// revoked. The phase is settled to absent only if it is still
    /// `.tearingDown(incarnation)`: a reinsertion enqueued after us set
    /// `.pendingRegistration(n+1)`, which its own registration advances.
    ///
    /// `paneRevoker` is optional only for hermetic tests; production installs it
    /// before `bind` (asserted in `main.swift`), so revocation is not silently
    /// skippable there.
    private func runTeardown(_ id: UUID, _ incarnation: UInt64) async {
        if let hook = transitionEntryHook { await hook() }
        await automationGrantStore.revokeForRemovedSession(id)
        await terminalAnchorStore.revokeForRemovedSession(id)
        // Every teardown reaches the cohort store, not just an explicit
        // `session.close`. A restore-batch reap removes sessions through this
        // same path, and a member the store still believed live would keep a
        // dead session in every sibling's membership.
        await cohortRevoker?(id, incarnation)
        await paneRevoker?(id)
        await eventBroker?.finishSession(id, withFinalEvent: .sessionClosed(sessionId: id.uuidString))
        if case .tearingDown(incarnation) = sessionPhase[id] {
            sessionPhase[id] = nil
        }
    }

    /// Set `id`'s phase to pending-registration for a freshly-inserted
    /// `incarnation` and enqueue its registration transition. Called
    /// synchronously right after the map insert.
    private func enqueueRegistration(_ id: UUID, _ incarnation: UInt64) -> Task<Void, Never> {
        sessionPhase[id] = .pendingRegistration(incarnation)
        return enqueueTransition(id) { [weak self] in await self?.runRegistration(id, incarnation) }
    }

    /// Claim + enqueue the teardown of `id`'s current incarnation. Called
    /// synchronously right after `removeSessionMaps`. Sets `.tearingDown` and
    /// enqueues the teardown transition; a second removal that finds the id
    /// ALREADY `.tearingDown` (a double removal of the same incarnation, no
    /// reinsertion in between, or the phase would be `.pendingRegistration`)
    /// coalesces by returning the in-flight teardown (the lane tail). Returns nil
    /// when there is nothing to tear down.
    private func enqueueTeardown(_ id: UUID, reason: TeardownReason) -> Task<Void, Never>? {
        switch sessionPhase[id] {
        case let .ready(incarnation), let .pendingRegistration(incarnation):
            sessionPhase[id] = .tearingDown(incarnation)
            // The reason separates a caller-requested close from daemon-side
            // reconciliation. A reap means a restore batch omitted a session
            // the daemon still held, which also revokes its pane
            // subscriptions.
            DiagnosticLog.session.notice(
                """
                teardown reason=\(reason.rawValue, privacy: .public) \
                incarnation=\(incarnation, privacy: .public)
                """
            )
            return enqueueTransition(id) { [weak self] in await self?.runTeardown(id, incarnation) }

        case .tearingDown:
            return lifecycleLane[id]

        case nil:
            return nil
        }
    }

    /// Reclaim every close tombstone whose id is NOT in `keep`: the ids a
    /// non-stale restore OMITS, whose closes the GUI's authoritative inventory
    /// has moved past. Sound because restores are serial: while this one is
    /// processing no other is pending, so dropping the omitted ids can't strand a
    /// fence a concurrent restore needs. After this the set is `⊆ keep`.
    private func reclaimTombstones(keeping keep: Set<UUID>) {
        guard !closeTombstones.isEmpty else { return }
        closeTombstones.formIntersection(keep)
    }

    /// Whether `key` strictly dominates the `existing` protection-ordering key,
    /// the same last-write-wins rule `setProtectedBatch` uses (`key <= existing`
    /// is stale). A nil `existing` (never touched) is dominated by any key.
    private func protectionDominates(_ key: ProtectionOrderingKey, over existing: ProtectionOrderingKey?) -> Bool {
        guard let existing else { return true }
        return !(key <= existing)
    }

    /// Mint a new session. Returns a `CreatedSession` bundling the in-memory
    /// `state` (which holds only a `CapabilityVerifier`) with the one-time
    /// bearer `capability`. The plaintext is produced and returned here and
    /// nowhere else: the caller hands `created.capability.token` to the
    /// client and keeps no copy; the daemon retains only the verifier.
    ///
    /// `name` is whatever the request supplied, stored as-is;
    /// `role` is `.agent` by default. The GUI's "Open Automation
    /// Tab" menu is the product-UI path that passes `.automation`;
    /// no CLI verb emits it, and the daemon refuses an
    /// automation mint that doesn't arrive over XPC from a
    /// signature-validated peer. Role is immutable for the
    /// session's lifetime: no role-mutation primitive exists on
    /// the wire. Daemon assigns `shortId` via
    /// `allocateUniqueShortID()`; collision retry is bounded by
    /// `ShortID.maxMintAttempts` so a degenerate RNG can't spin.
    ///
    /// `epoch` is the creating connection's id (0 for direct test/tooling
    /// callers). It stamps `sessionAssertionKey` at the `.liveAuthority` tier so
    /// a later `restoreBatch` reconciles this session correctly: a restore on the
    /// SAME connection that merely raced this create can't reap it (live
    /// authority outranks the restore baseline at one epoch), if the GUI still
    /// holds it a later restore re-asserts it, and if the GUI has since dropped
    /// it a restore from a strictly-newer connection reconciles it away.
    ///
    /// `restorable` marks a session that a GUI restore could later resurrect.
    /// It is true only when the validated GUI mints it. It gates whether the
    /// session's close leaves a tombstone (see `closeTombstones`): a non-GUI session (an
    /// agent's own, or an attacker churning `session.create`/`.close`) is never in
    /// a GUI inventory, so it needs none and can't grow the set.
    public func createSession(
        label: String?,
        name: String? = nil,
        role: SessionRole = .agent,
        owner: OwnerProcessIdentity? = nil,
        initialProtected: Bool = false,
        epoch: UInt64 = 0,
        restorable: Bool = false,
        tabId: UUID? = nil
    ) async throws -> CreatedSession {
        let id = UUID()
        let capability = try Capability.random()
        let shortId = try allocateUniqueShortID()
        let state = SessionState(
            id: id,
            capabilityVerifier: CapabilityVerifier(for: capability),
            shortId: shortId,
            label: label,
            name: name,
            createdAt: now(),
            role: role,
            // Owner liveness (orphan recovery) reads the pid; provenance reads
            // the full identity. Both derive from the captured peer identity,
            // never a caller-supplied field.
            ownerPID: owner?.pid,
            owner: owner,
            tabId: tabId
        )
        sessions[id] = state
        // Seed protection in the SAME actor turn as `sessions[id]`, before ANY
        // `await` below. A terminal joining a protected tab must never be
        // observable as unprotected: the store registration and the publish are
        // all `await`s, and a `tabs.list` racing any of those suspensions
        // (actor reentrancy) would see an unprotected row for it if
        // protection were seeded
        // later. Inserting before the first await closes that window.
        if initialProtected {
            protectedSessions.insert(id)
        }
        // Stamp the assertion key at the `.liveAuthority` tier so an
        // authoritative `restoreBatch` reconciliation can tell this live session
        // apart from an abandoned ghost, and can't reap it from a same-epoch
        // restore that merely raced the create. Same actor turn as the insert,
        // before any await.
        sessionAssertionKey[id] = ProtectionOrderingKey(epoch: epoch, revision: 0, tier: .liveAuthority)
        // Track a GUI-minted session as restorable, so its later close leaves a
        // tombstone that fences a stale restore from resurrecting it. Non-GUI
        // sessions never appear in a GUI inventory, so they are not tracked.
        if restorable { restorableSessions.insert(id) }
        // Allocate this session's incarnation, mark it PENDING registration, and
        // enqueue its registration transition on the id's lane, all in the same
        // actor turn as the insert. Await the transition so `createSession`
        // returns only once the session is registered, ready, and its
        // `.sessionCreated` published (the transition does all three). A request
        // racing before it completes sees `notReady`; the client can't target
        // this session before `createSession` returns anyway (no cap yet).
        let incarnation = allocateIncarnation()
        let registration = enqueueRegistration(id, incarnation)
        await registration.value
        return CreatedSession(state: state, capability: capability)
    }

    /// Check that `(sessionId, capability)` matches a live session.
    /// Returns the matching state on success, throws otherwise. The
    /// throwing shape is what callers want: the error flows up to the
    /// RPC layer, which maps `notFound` and `invalidCapability` to
    /// their distinct wire codes.
    public func validate(sessionId: UUID, capability: Capability) throws -> SessionState {
        guard let state = sessions[sessionId] else {
            throw SessionError.notFound(sessionId: sessionId)
        }
        guard state.capabilityVerifier.matches(capability) else {
            throw SessionError.invalidCapability(sessionId: sessionId)
        }
        return state
    }

    /// Membership check: true iff a session with this id still
    /// exists in the manager. Distinct from `validate` because it
    /// doesn't require capabilities (the caller is daemon-internal,
    /// not an external RPC client). Use `isAlive` for the dedup-
    /// adoption decision in `PaneCoordinator.createSim`; `contains`
    /// is the weaker check (a crashed GUI leaves the SessionManager
    /// entry intact, so `contains` returns true while `isAlive`
    /// returns false).
    public func contains(_ sessionId: UUID) -> Bool {
        sessions[sessionId] != nil
    }

    /// Liveness check: true iff the session exists AND its
    /// recorded owner pid still refers to a live process, judged by
    /// the injected `isProcessAlive` predicate (the `kill(pid, 0)`
    /// ping documented on `processIsAlive`: only `ESRCH` reads as
    /// dead, and every other errno as alive, including `EPERM` for a
    /// live process under a different uid).
    ///
    /// **Defaults.** Sessions whose `ownerPID` is nil or <= 0 (the daemon
    /// couldn't attribute them to a live peer: a test/tooling constructor)
    /// fall back to "assume alive", so the dedup gate rejects cross-session
    /// conflicts and stays idempotent same-session. Only a session the daemon
    /// captured an owner for reaches the orphan-adoption branch. `ownerPID` is
    /// always derived server-side from `owner`, never supplied by a caller.
    ///
    /// **Pid reuse.** A naive pid check can mis-classify a dead
    /// session as alive if the OS recycled the pid for an
    /// unrelated process. With a single long-lived GUI and a
    /// small recovery window this is rare enough to accept. The
    /// stronger fix, pairing the pid with the process' start
    /// time, is not implemented.
    public func isAlive(_ sessionId: UUID) -> Bool {
        guard let state = sessions[sessionId] else { return false }
        guard let pid = state.ownerPID, pid > 0 else { return true }
        return isProcessAlive(pid)
    }

    /// Drop a session. Validates the credentials first, so a stale
    /// shell can't close a sibling session by guessing its UUID.
    public func closeSession(sessionId: UUID, capability: Capability) async throws {
        _ = try validate(sessionId: sessionId, capability: capability)
        await teardownSession(sessionId)
    }

    /// Tear down a session's live state, revoke its store registrations, and
    /// publish its close. Called by `closeSession` (after a cap check). The
    /// synchronous map removals happen before the first `await`, so a
    /// concurrent `tabs.list` never sees a half-removed session. `restoreBatch`
    /// does not call this; it splits the two halves so all its map mutations
    /// stay in one await-free segment (see there).
    private func teardownSession(_ sessionId: UUID) async {
        // Tombstone the closed id ONLY if it was restorable (GUI-created or
        // restored); only those can be resurrected by a stale, already-captured
        // GUI restore. `removeSessionMaps` clears `restorableSessions`, so read
        // membership first. Ghost reconciliation goes through `removeSessionMaps`
        // directly (no tombstone) and relies on the `lastRestorationKey`
        // staleness fence instead.
        let wasRestorable = restorableSessions.contains(sessionId)
        removeSessionMaps(sessionId)
        if wasRestorable { closeTombstones.insert(sessionId) }
        // Enqueue the teardown transition on the id's lane (claimed atomically,
        // same turn as `removeSessionMaps`) and await THAT transition's own
        // handle, scoped to this incarnation, so the close returns only after
        // its teardown (store revoke + subscription sweep + event finish)
        // completes. A double removal coalesces onto the in-flight teardown.
        if let teardown = enqueueTeardown(sessionId, reason: .sessionClose) {
            await teardown.value
        }
    }

    /// The synchronous half of a teardown: drop the session from every in-memory
    /// map. Safe to call from an await-free segment.
    private func removeSessionMaps(_ sessionId: UUID) {
        sessions.removeValue(forKey: sessionId)
        protectedSessions.remove(sessionId)
        displayTitles.removeValue(forKey: sessionId)
        displayTitleWriters.removeValue(forKey: sessionId)
        protectionOrdering.removeValue(forKey: sessionId)
        sessionAssertionKey.removeValue(forKey: sessionId)
        restorableSessions.remove(sessionId)
    }

    /// Atomically set the protection flag for a set of sessions: the
    /// terminal-pane sessions of one tab. Validates that **every** id
    /// names a live session FIRST; if any is unknown it throws
    /// `SessionError.notFound` for that id and mutates nothing, so a
    /// partial batch can never leave the daemon holding a mixed
    /// protected/unprotected set the GUI's single tab boolean can't represent.
    /// After validation it flips the whole set in one synchronous actor turn
    /// (no interior `await`, so no other actor message interleaves between
    /// validation and application). Nothing is written to disk; the daemon
    /// holds session state in memory only.
    ///
    /// No capability check: this is `.validatedGUI`-scoped, so the peer's
    /// audit token is the authority and the GUI is the trusted resolver
    /// of a tab's session set.
    ///
    /// The daemon is the ordering authority. `key = (epoch, revision)`
    /// (`epoch` = the caller's monotonic XPC connection id) is compared
    /// against every target session's last-applied key. Validation and
    /// the dominance check run over the *whole* batch first; then it
    /// either applies to every session or, if stale for any one of them,
    /// returns `applied: false` without mutating anything. This is what
    /// lets the GUI stop serializing sends: an older write arriving late
    /// (even across an XPC reconnect, or a GUI restart replaying low
    /// revisions) loses because its key does not dominate. `isProtected` is
    /// the desired absolute state, so a re-applied winning batch is a
    /// no-op.
    @discardableResult
    public func setProtectedBatch(
        sessionIds: [UUID],
        isProtected: Bool,
        revision: Int,
        epoch: UInt64
    ) throws -> SessionSetProtectedBatchResult {
        for id in sessionIds where sessions[id] == nil {
            throw SessionError.notFound(sessionId: id)
        }
        let key = ProtectionOrderingKey(epoch: epoch, revision: revision)
        // Stale iff the key fails to strictly dominate ANY target
        // session's last-applied key. All-or-none: one stale member
        // rejects the whole batch, so a tab's sessions never split.
        let isStale = sessionIds.contains { id in
            if let existing = protectionOrdering[id] { return key <= existing }
            return false
        }
        if isStale {
            return SessionSetProtectedBatchResult(
                applied: false,
                revision: revision,
                isProtected: isProtected
            )
        }
        for id in sessionIds {
            if isProtected {
                protectedSessions.insert(id)
            } else {
                protectedSessions.remove(id)
            }
            protectionOrdering[id] = key
        }
        return SessionSetProtectedBatchResult(
            applied: true,
            revision: revision,
            isProtected: isProtected
        )
    }

    /// Ordering-fenced authoritative protection snapshot. In one actor turn:
    /// snapshot every requested session (explicit `.missing` for an unknown
    /// id) and, if `(epoch, revision)` strictly dominates every LIVE requested
    /// session's current key, advance them all to that key
    /// without changing protection. Advancing is the fence: a delayed older
    /// write now fails the dominance check and returns `applied: false`, so
    /// the snapshot the GUI receives can't already be obsolete. `fenced` is
    /// false (and nothing is advanced) when a newer authority already
    /// exists on some session; the GUI treats that as unresolved.
    public func protectionSnapshot(
        sessionIds: [UUID],
        revision: Int,
        epoch: UInt64
    ) -> SessionProtectionSnapshotResult {
        let key = ProtectionOrderingKey(epoch: epoch, revision: revision)
        let fenced = !sessionIds.contains { id in
            guard sessions[id] != nil, let existing = protectionOrdering[id] else { return false }
            return key <= existing
        }
        if fenced {
            for id in sessionIds where sessions[id] != nil {
                protectionOrdering[id] = key
            }
        }
        let entries = sessionIds.map { id -> SessionProtectionEntry in
            guard sessions[id] != nil else {
                return SessionProtectionEntry(sessionId: id.uuidString, state: .missing)
            }
            return SessionProtectionEntry(
                sessionId: id.uuidString,
                state: protectedSessions.contains(id) ? .protectedState : .unprotectedState
            )
        }
        return SessionProtectionSnapshotResult(fenced: fenced, revision: revision, sessions: entries)
    }

    /// Whether the session carries the protection flag. Returns false
    /// for unknown sessions (no leak: the caller's filter sees the
    /// session as unprotected and the listing path drops it via the
    /// existence check anyway).
    public func isProtected(_ sessionId: UUID) -> Bool {
        protectedSessions.contains(sessionId)
    }

    /// Cache the tab's live label, or clear it when `title` normalizes to
    /// nil. No capability check: `.validatedGUI`-scoped, so the peer's
    /// audit token is the authority and the GUI is the only writer.
    ///
    /// The session must be live. Rejecting an unknown id keeps a client
    /// bug (a push racing a close, a stale queued update) from accreting
    /// titles for dead sessions in a map nothing would ever clean up.
    ///
    /// Normalization is applied here as well as client-side: the client's
    /// pass bounds the payload, this one is the enforcement that holds
    /// regardless of what a client sends.
    ///
    /// A push from a connection strictly older than the one that last wrote
    /// this session's title is dropped, not rejected: the newer value is
    /// already correct, so there is nothing for the caller to retry. See
    /// `displayTitleWriters` for why "older" is decidable.
    public func setDisplayTitle(
        sessionId: UUID,
        title: String?,
        fromConnection connectionId: UInt64
    ) throws {
        guard sessions[sessionId] != nil else {
            throw SessionError.notFound(sessionId: sessionId)
        }
        if let lastWriter = displayTitleWriters[sessionId], connectionId < lastWriter {
            return
        }
        displayTitleWriters[sessionId] = connectionId
        if let normalized = DisplayTitleNormalizer.normalize(title) {
            displayTitles[sessionId] = normalized
        } else {
            displayTitles.removeValue(forKey: sessionId)
        }
    }

    /// The session's cached live label, or nil when none was pushed.
    /// **Unfiltered:** it answers for any session, protected or not. Code
    /// serving a client must go through `sessionsWithDisplayTitles(visibleTo:)`,
    /// which pairs each title with the protection-filtered session projection.
    func displayTitle(_ sessionId: UUID) -> String? {
        displayTitles[sessionId]
    }

    /// Snapshot of all sessions, ordered by creation time. Used by
    /// `tabs.list`; capabilities are *not* exposed by this method.
    public func allSessions() -> [SessionState] {
        sessions.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Look up one session by id. Returns nil when the session has
    /// been closed (or never existed). Used by the status-item
    /// controller to map an owned sim's `sessionId` to a readable
    /// group header for the menu.
    public func session(id: UUID) -> SessionState? {
        sessions[id]
    }

    /// Sessions visible to a caller. Protected sessions are filtered
    /// out unless the caller is authenticated as that session (the
    /// owner sees its own protected tab). An unauthenticated caller,
    /// daemon-wide with no creds, gets only non-protected sessions.
    public func sessions(visibleTo callerSessionId: UUID?) -> [SessionState] {
        sessions.values
            .filter { state in
                !protectedSessions.contains(state.id) || state.id == callerSessionId
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The `sessions(visibleTo:)` projection paired with each session's
    /// cached display title, in one actor turn so a title can't be read
    /// against a session set the same listing didn't see. Titles ride the
    /// same protection filter for free: a protected tab's label is exactly as
    /// visible as the tab itself.
    public func sessionsWithDisplayTitles(
        visibleTo callerSessionId: UUID?
    ) -> [(state: SessionState, displayTitle: String?)] {
        sessions(visibleTo: callerSessionId).map { ($0, displayTitles[$0.id]) }
    }

    // MARK: - Helpers

    /// Loop the configured `mintShortID` strategy until a value
    /// outside the live short_id set is produced or
    /// `ShortID.maxMintAttempts` attempts elapse. Bounded retry: a
    /// buggy strategy or a pathologically saturated alphabet surfaces
    /// as `shortIDExhausted` rather than locking the actor.
    private func allocateUniqueShortID() throws -> String {
        let existing = Set(sessions.values.map(\.shortId))
        for _ in 0..<ShortID.maxMintAttempts {
            let candidate = mintShortID()
            if !existing.contains(candidate) { return candidate }
        }
        throw SessionError.shortIDExhausted
    }
}

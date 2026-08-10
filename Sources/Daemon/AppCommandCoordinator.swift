// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppCommandCoordinator: the daemon-side broker for the
// `app.commands` back-channel that lets CLI verbs reach into the
// GUI for tab / pane / window operations.
//
// Three responsibilities, all behind actor isolation:
//   1. Maintain the singleton `AsyncStream<AppCommand>` the GUI's
//      `app.commands` subscription drains.
//   2. Hand out `commandId`s and hold a continuation per pending
//      command so the originating RPC handler (`tab.close`,
//      `windows.list`, etc.) can `await` the GUI's reply.
//   3. Route `AppCommandResult` frames (from `app.commandResult`)
//      back to the matching continuation. Includes a wall-clock
//      timeout so a wedged or absent GUI doesn't leak a continuation
//      forever. The handler resolves with `guiUnavailable`.
//
// Single-subscriber assumption: deviceterm runs one GUI process at a
// time (multi-window but single-process). If the GUI is up,
// it holds the subscription. If no subscription is active, every
// `await` returns `guiUnavailable` immediately rather than waiting
// for the timer.

import DaemonProtocol
import Foundation

public actor AppCommandCoordinator {
    // MARK: - Subtypes

    /// Outcome the originating handler resumes with. Errors carry a
    /// stable code so the CLI layer can render without re-classifying.
    public enum CommandOutcome: Sendable {
        case ok
        case data(Data)                       // JSON payload
        case error(
            code:
            String,
            message: String
            )
    }

    private struct PendingCommand {
        let continuation: CheckedContinuation<CommandOutcome, Never>
        let timeoutTask: Task<Void, Never>
    }

    // MARK: - Type properties

    /// How long to wait for the GUI to reply with `app.commandResult`
    /// before failing the command with `intent.guiUnavailable`. 5s is
    /// generous for a GUI under load but not so long that a wedged
    /// app strands the CLI caller indefinitely.
    public static let defaultTimeoutMs: Int = 5_000

    // MARK: - Instance properties

    /// Active subscription continuation. `nil` when no GUI is
    /// subscribed; setting a new one replaces the old (single-
    /// subscriber model; multi-GUI is out of scope).
    private var subscriberContinuation: AsyncStream<AppCommand>.Continuation?
    /// The daemon-assigned connection id of the current subscriber. The
    /// back-channel is pinned to one connection: only this connection
    /// may deliver results, and only a teardown *for this connection*
    /// clears the subscription. `connectionId` is daemon-minted, never
    /// crosses the wire, and UDS/XPC use disjoint ranges, so it can't
    /// be guessed or claimed by another local process.
    private var subscriberConnectionId: UInt64?
    /// Monotonic id for the current subscription *instance*. Teardown is
    /// matched on this, not on `connectionId`: a stale `onCancel` (even
    /// from the same connection re-subscribing) must never tear down a
    /// newer subscription. `connectionId` stays the authority for
    /// `deliverResult` (who may answer); the generation is the identity
    /// for *which* subscription a teardown belongs to.
    private var subscriberGeneration: UInt64 = 0
    /// Pending commands keyed by their `commandId`.
    private var pending: [String: PendingCommand] = [:]

    /// Count of pending commands. Tests use this to verify resume
    /// + cleanup happen exactly once per command.
    public var pendingCount: Int { pending.count }

    /// Whether a GUI subscription is currently registered.
    public var hasSubscriber: Bool { subscriberContinuation != nil }

    /// The current subscriber's connection id, or `nil` if none.
    public var subscriberConnection: UInt64? { subscriberConnectionId }

    // MARK: - Init

    public init() {}

    // MARK: - Subscription (GUI side)

    /// Begin a new subscription for the connection `connectionId`.
    /// Returns the stream the dispatcher connects to its outbound write
    /// loop and an unregister closure the dispatcher runs in
    /// `onCancel`. Eviction is last-wins: a second subscriber (the real
    /// GUI re-subscribing after a relaunch) takes over cleanly, and the
    /// prior subscriber's pending commands fail immediately.
    public func subscribe(connectionId: UInt64) -> (
        stream: AsyncStream<AppCommand>,
        onCancel: @Sendable () -> Void
    ) {
        // Evict any prior subscriber explicitly (finish its stream and
        // fail its in-flight commands now) rather than relying on the
        // old subscription's async `onCancel`, which could otherwise
        // land *after* this new subscriber registers and tear the live
        // GUI down (a latent teardown race the connection-scoped
        // `subscriptionFinished` guard below also closes).
        evictCurrentSubscriber()
        let (stream, continuation) =
            AsyncStream<AppCommand>.makeStream()
        subscriberContinuation = continuation
        subscriberConnectionId = connectionId
        subscriberGeneration &+= 1
        let generation = subscriberGeneration
        let coord = self
        let onCancel: @Sendable () -> Void = {
            Task { await coord.subscriptionFinished(generation: generation) }
        }
        return (stream, onCancel)
    }

    /// Finish the current subscription's stream and fail every pending
    /// command. Shared by explicit eviction (a new GUI subscribed) and
    /// by a matching teardown.
    private func evictCurrentSubscriber() {
        subscriberContinuation?.finish()
        subscriberContinuation = nil
        subscriberConnectionId = nil
        failAllPending()
    }

    /// Fail every pending command with `guiUnavailable` and clear the
    /// bookkeeping. The GUI subscription that would have answered them
    /// is gone.
    private func failAllPending() {
        let stragglers = pending
        pending.removeAll()
        for (_, record) in stragglers {
            record.timeoutTask.cancel()
            record.continuation.resume(
                returning: .error(
                code: "intent.guiUnavailable",
                message: "GUI subscription closed before this command completed"
            )
                )
        }
    }

    /// Called by a subscription's `onCancel`. No-ops unless the
    /// teardown is for the *current* subscription instance: a stale
    /// `onCancel` from an already-evicted subscription (a relaunch on a
    /// new connection, or the same connection re-subscribing) must not
    /// unsubscribe the live GUI. Only a generation-matched teardown
    /// clears state and fails pending commands.
    private func subscriptionFinished(generation: UInt64) {
        guard generation == subscriberGeneration else { return }
        evictCurrentSubscriber()
    }

    // MARK: - Publish + await (handler side)

    /// Publish an `AppCommand` and await the GUI's reply. The handler
    /// builds the kind + params + originatingSessionId and calls
    /// this; the returned `CommandOutcome` carries either `ok`, a
    /// JSON `data` payload (info verbs), or an error.
    public func publishAndAwait(
        kind: AppCommandKind,
        originatingSessionId: String?,
        params: Data,
        timeoutMs: Int = AppCommandCoordinator.defaultTimeoutMs
    ) async -> CommandOutcome {
        guard let subscriber = subscriberContinuation else {
            return .error(
                code: "intent.guiUnavailable",
                message: "no GUI subscription active; the DeviceTerm app "
                    + "isn't running or hasn't established its "
                    + "back-channel yet"
            )
        }
        let commandId = UUID().uuidString
        let command = AppCommand(
            commandId: commandId,
            kind: kind,
            originatingSessionId: originatingSessionId,
            params: params
        )
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandOutcome, Never>) in
            // Spin a timeout task BEFORE yielding to the GUI so a
            // GUI that exits between yield and our register can't
            // strand the continuation.
            let timeout = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(timeoutMs) * 1_000_000
                )
                if Task.isCancelled { return }
                await self?.fireTimeout(
                    commandId: commandId,
                    timeoutMs: timeoutMs
                )
            }
            pending[commandId] = PendingCommand(
                continuation: cont,
                timeoutTask: timeout
            )
            subscriber.yield(command)
        }
    }

    /// Called by the `app.commandResult` RPC handler when the GUI
    /// replies. Accepts the result only from the **current subscriber
    /// connection**. A result from any other connection is a forgery
    /// attempt and returns `false` (the handler turns that into a
    /// role-violation reject). Resumes the matching continuation and
    /// cancels its timeout. An unknown `commandId` from the correct
    /// subscriber (e.g. a result for a command that already timed out)
    /// is not a violation. It returns `true` and is silently dropped.
    @discardableResult
    public func deliverResult(
        _ result: AppCommandResult,
        from connectionId: UInt64
    ) -> Bool {
        guard connectionId == subscriberConnectionId else { return false }
        guard let record = pending.removeValue(
            forKey: result.commandId
        ) else { return true }
        record.timeoutTask.cancel()
        let outcome: CommandOutcome
        switch result.status {
        case "ok":
            outcome = .ok

        case "data":
            outcome = .data(result.data ?? Data("{}".utf8))

        case "error":
            let err = result.error ?? AppCommandResult.ErrorPayload(
                code: "intent.internalError",
                message: "GUI returned error without payload"
            )
            outcome = .error(code: err.code, message: err.message)

        default:
            outcome = .error(
                code: "intent.internalError",
                message: "unknown AppCommandResult status: \(result.status)"
            )
        }
        record.continuation.resume(returning: outcome)
        return true
    }

    /// Timeout fan-out. Resumes the pending continuation with
    /// `guiUnavailable` and drops the bookkeeping record.
    private func fireTimeout(commandId: String, timeoutMs: Int) {
        guard let record = pending.removeValue(forKey: commandId) else { return }
        record.continuation.resume(
            returning: .error(
            code: "intent.guiUnavailable",
            message: "no GUI response within \(timeoutMs)ms"
        )
            )
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppCommandSubscriber: the GUI's consumer of the daemon's
// `app.commands` back-channel.
//
// At app startup `AppDelegate` constructs one of these, hands it the
// `IntentDispatcher` (the single point that resolves refs, dispatches
// Routes, and returns `IntentResult`), and spins a long-lived drain
// task. The subscriber translates each `AppCommand` frame to the
// matching `RouteIntent`, awaits the dispatch result, and acks via
// `app.commandResult` so the daemon's coordinator can resume the
// originating CLI handler's continuation.
//
// Single subscription assumption: one GUI process per daemon. The
// daemon coordinator's `subscribe()` replaces any prior subscription,
// so a relaunched GUI takes over cleanly.

import DaemonProtocol
import Foundation

@MainActor
final class AppCommandSubscriber {
    /// Mirror of the daemon's `RPCMethodError.roleViolationCode`
    /// (`Sources/Daemon/RPCMethodError.swift`). The daemon module isn't
    /// linkable from the GUI, so the wire code is mirrored here. It is a
    /// definite/terminal signature rejection on BOTH transports: the `--smoke`
    /// UDS fallback structurally can't carry the `.validatedGUI` back-channel
    /// (no audit token), and over XPC it means the peer's signature stably
    /// failed validation. Either way retrying can't succeed, so a match stops
    /// the loop. The transient, retryable validation-unavailable outcome is a
    /// distinct code (`notReadyCode`, -32002) the daemon leaves uncached.
    private static let backChannelRefusedCode = -32_011

    private let dispatcher: IntentDispatcher
    private let daemon: any AppCommandControlling
    /// Public so tests can introspect lifecycle (subscriber up,
    /// drain task active, etc.) without poking at private state.
    private(set) var drainTask: Task<Void, Never>?

    init(dispatcher: IntentDispatcher, daemon: any AppCommandControlling) {
        self.dispatcher = dispatcher
        self.daemon = daemon
    }

    /// Whether `error` carries the back-channel refusal wire code (-32011), a
    /// terminal signature rejection on either transport. A transient
    /// validation-unavailable outcome uses a distinct code (-32002) and is not
    /// matched here, so it stays on the retry path.
    private static func isBackChannelRefused(_ error: Error) -> Bool {
        if case let DaemonClientError.daemon(code, _) = error {
            return code == backChannelRefusedCode
        }
        return false
    }

    /// Begin draining. Idempotent. Calling twice is a no-op.
    func start() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drainLoop()
        }
    }

    /// Cancel the drain. Used during app teardown so the Task doesn't
    /// outlive the AppDelegate.
    func stop() {
        drainTask?.cancel()
        drainTask = nil
    }

    /// Main loop. Re-establishes the subscription on transport errors
    /// (daemon restart, transient drop) with backoff so a wedged
    /// daemon doesn't spin the CPU.
    private func drainLoop() async {
        var backoffMs = 200
        while !Task.isCancelled {
            do {
                try await subscribeAndDrain()
                backoffMs = 200  // reset after a successful drain
            } catch {
                if Task.isCancelled { return }
                if Self.isBackChannelRefused(error) {
                    // -32011 is a definite/terminal signature rejection on
                    // either transport: the `--smoke` UDS fallback can't carry
                    // the `.validatedGUI` back-channel (no audit token), and
                    // over XPC the peer's signature stably failed validation.
                    // Retrying can't succeed, so log once and stop rather than
                    // spin at the backoff ceiling. A transient
                    // validation-unavailable outcome is a distinct code (-32002)
                    // that is NOT matched here, so it stays on the retry path.
                    let note = "deviceterm: app.commands back-channel refused "
                        + "(GUI signature not validated); multi-tab pane "
                        + "control unavailable\n"
                    FileHandle.standardError.write(Data(note.utf8))
                    return
                }
                // Log + back off. Failures are typically "daemon went
                // down for restart" or "transport hiccup"; both are
                // transient on this path.
                FileHandle.standardError.write(
                    Data(
                    "deviceterm: app.commands subscription lost: \(error)\n".utf8
                )
                    )
                try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                backoffMs = min(backoffMs * 2, 5_000)
            }
        }
    }

    /// One subscription session: open the stream, drain every
    /// AppCommand frame, exit when the stream finishes. Throws on
    /// transport errors so the outer loop can re-establish.
    private func subscribeAndDrain() async throws {
        let (_, events) = try await daemon.subscribeAppCommands()
        for await (method, payload) in events {
            guard method == "app.command" else { continue }
            await handleCommand(payload: payload)
        }
    }

    /// Decode one AppCommand frame, translate to RouteIntent,
    /// dispatch, and ack via `app.commandResult`.
    private func handleCommand(payload: Data) async {
        let command: AppCommand
        do {
            command = try JSONDecoder().decode(AppCommand.self, from: payload)
        } catch {
            FileHandle.standardError.write(
                Data(
                "deviceterm: malformed AppCommand frame: \(error)\n".utf8
            )
                )
            return
        }
        let intent: RouteIntent
        do {
            intent = try CLIIntentTranslator.translate(command)
        } catch let error as IntentError {
            await sendResult(
                .error(
                commandId: command.commandId,
                code: error.code,
                message: error.hint
            )
                )
            return
        } catch {
            await sendResult(
                .error(
                commandId: command.commandId,
                code: "intent.internalError",
                message: String(describing: error)
            )
                )
            return
        }
        let result = await dispatcher.dispatch(
            intent,
            origin: .external(sessionID: command.originatingSessionId)
        )
        let wire = encode(result: result, commandId: command.commandId)
        await sendResult(wire)
    }

    private func encode(
        result: IntentResult,
        commandId: String
    ) -> AppCommandResult {
        switch result {
        case .ok:
            return .ok(commandId: commandId)

        case let .data(response):
            let payload: Data
            switch response {
            case let .tabInfo(info):
                payload = (try? JSONEncoder().encode(info)) ?? Data("{}".utf8)

            case let .paneInfo(info):
                payload = (try? JSONEncoder().encode(info)) ?? Data("{}".utf8)

            case let .windowsList(info):
                payload = (try? JSONEncoder().encode(info)) ?? Data("[]".utf8)

            case let .tabCapture(capture):
                payload = (try? JSONEncoder().encode(capture)) ?? Data("{}".utf8)

            case let .tabSetPrivate(result):
                payload = (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
            }
            return .data(commandId: commandId, payload: payload)

        case let .error(error):
            return .error(
                commandId: commandId,
                code: error.code,
                message: error.hint
            )
        }
    }

    private func sendResult(_ result: AppCommandResult) async {
        do {
            try await daemon.sendAppCommandResult(result)
        } catch {
            FileHandle.standardError.write(
                Data(
                "deviceterm: failed to send app.commandResult: \(error)\n".utf8
            )
                )
        }
    }
}

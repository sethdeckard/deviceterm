// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppCommandGrantRelayTests: what `publishVerb` puts on the wire and
// what it does with the answer.
//
// This suite covers two daemon-side behaviors:
//   - The published command carries the caller's live grant, read
//     server-side from the store rather than taken from the request.
//   - A GUI refusal for want of a grant comes back as the same numeric
//     code the daemon's own scope check produces, so an agent branches
//     on one number whichever layer refused. Everything else keeps
//     riding the generic code unchanged.

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

struct AppCommandGrantRelayTests {
    /// Publish through `publishVerb` while a fake GUI answers with
    /// `reply`, and hand back both the command the GUI saw and whatever
    /// the handler threw or returned.
    private func relay(
        grantedSession: UUID?,
        callerSession: UUID?,
        reply: @escaping @Sendable (String) -> AppCommandResult
    ) async -> (published: AppCommand?, thrown: RPCMethodError?) {
        let coordinator = AppCommandCoordinator()
        let store = AutomationGrantStore()
        if let grantedSession {
            await store.registerSession(grantedSession)
            await store.grant(
                sessionIds: [grantedSession],
                key: GrantOrderingKey(epoch: 1, revision: 1),
                issuedBy: 1
            )
        }
        let (stream, _) = await coordinator.subscribe(connectionId: 1)
        let seen = SeenCommand()
        Task {
            for await command in stream {
                await seen.record(command)
                await coordinator.deliverResult(reply(command.commandId), from: 1)
                break
            }
        }
        let handler = AppCommandMethods.publishVerb(
            kind: .tabClose,
            coordinator: coordinator,
            automationGrant: store
        )
        var thrown: RPCMethodError?
        await SessionDispatchContext.$originatingSessionId.withValue(
            callerSession?.uuidString
        ) {
            do {
                _ = try await handler(
                    Data(#"{"tab":{"type":"current"},"mode":"detach"}"#.utf8)
                )
            } catch let error as RPCMethodError {
                thrown = error
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
        return (await seen.command, thrown)
    }

    // MARK: - The grant rides on the command

    @Test
    func aGrantedSessionPublishesWithTheGrantSet() async {
        let session = UUID()
        let outcome = await relay(
            grantedSession: session,
            callerSession: session,
            reply: { .ok(commandId: $0) }
        )
        #expect(outcome.published?.originAutomationGrant == true)
        #expect(outcome.published?.originatingSessionId == session.uuidString)
    }

    @Test
    func anUngrantedSessionPublishesWithoutIt() async {
        let outcome = await relay(
            grantedSession: nil,
            callerSession: UUID(),
            reply: { .ok(commandId: $0) }
        )
        #expect(outcome.published?.originAutomationGrant == false)
    }

    @Test
    func aGrantForAnotherSessionDoesNotTravel() async {
        // The store is keyed by session, and the handler reads it for the
        // *caller's* id. A grant living elsewhere must not leak onto this
        // command.
        let outcome = await relay(
            grantedSession: UUID(),
            callerSession: UUID(),
            reply: { .ok(commandId: $0) }
        )
        #expect(outcome.published?.originAutomationGrant == false)
    }

    @Test
    func anOutOfTabCallerPublishesWithoutAGrant() async {
        // No session id at all (a stock terminal). Nothing to look up,
        // so it fails closed rather than reading as granted.
        let outcome = await relay(
            grantedSession: nil,
            callerSession: nil,
            reply: { .ok(commandId: $0) }
        )
        #expect(outcome.published?.originAutomationGrant == false)
        #expect(outcome.published?.originatingSessionId == nil)
    }

    // MARK: - The refusal comes back as one number

    @Test
    func aGUIAutomationRefusalArrivesAsAScopeViolation() async {
        let outcome = await relay(
            grantedSession: nil,
            callerSession: UUID(),
            reply: {
                .error(
                    commandId: $0,
                    code: IntentErrorCode.automationRequired,
                    message: "tab close outside your own tab needs a grant"
                )
            }
        )
        #expect(outcome.thrown?.code == RPCMethodError.scopeViolationCode)
    }

    @Test
    func everyOtherIntentErrorKeepsTheGenericCode() async {
        // The remap is one code, not a category. A `notFound` must not
        // start reading as a permission problem.
        let outcome = await relay(
            grantedSession: nil,
            callerSession: UUID(),
            reply: {
                .error(
                    commandId: $0,
                    code: "intent.notFound",
                    message: "tab 'abc' not found"
                )
            }
        )
        #expect(outcome.thrown?.code == -32_099)
    }
}

/// Captures the command the fake GUI subscriber received.
private actor SeenCommand {
    private(set) var command: AppCommand?

    func record(_ command: AppCommand) {
        self.command = command
    }
}

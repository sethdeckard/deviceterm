// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DeviceTermCLI
import Foundation
import Testing

private func outputString(_ outcome: CommandOutcome) -> String? {
    String(data: outcome.stdout, encoding: .utf8)
}

@Test
func jsonFailureEncodesStableEnvelope() {
    let failure = CommandOutcome.failure(
        code: .transportUnavailable,
        message: "no daemon"
    )
    let outcome = failure.renderingFailure(for: .tabsList, output: .json)

    #expect(
        outputString(outcome)
            == #"{"error":{"code":"transport.unavailable","message":"no daemon"}}"# + "\n"
    )
    #expect(outcome.stderr == "no daemon")
    #expect(outcome.exitCode == 1)
}

@Test
func jsonFailureIncludesObjectDetails() throws {
    let details = try JSONSerialization.data(
        withJSONObject: ["rpcCode": -32_001, "stage": "authentication"]
    )
    let failure = CommandOutcome.failure(
        code: .sessionUnauthorized,
        message: "authentication failed",
        details: details
    )
    let outcome = failure.renderingFailure(for: .tabsList, output: .json)

    let expected = #"{"error":{"code":"session.unauthorized","details":{"rpcCode":-32001,"#
        + #""stage":"authentication"},"message":"authentication failed"}}"#
    #expect(outputString(outcome) == expected + "\n")
}

@Test
func jsonFailureOmitsMalformedDetails() {
    let failure = CommandOutcome.failure(
        code: .protocolInvalidResponse,
        message: "bad response",
        details: Data("not json".utf8)
    )
    let outcome = failure.renderingFailure(for: .tabsList, output: .json)

    #expect(
        outputString(outcome)
            == #"{"error":{"code":"protocol.invalidResponse","message":"bad response"}}"# + "\n"
    )
}

@Test
func humanFailureRemainsStderrOnly() {
    let original = CommandOutcome.failure(
        code: .paneNotFound,
        message: "no pane"
    )
    let rendered = original.renderingFailure(for: .tap(pane: nil, x: 0.5, y: 0.5), output: .human)

    #expect(rendered == original)
    #expect(rendered.stdout.isEmpty)
}

@Test
func axFailureRendersJSONWithoutFlag() {
    let failure = CommandOutcome.failure(
        code: .paneAmbiguous,
        message: "multiple panes"
    )
    let outcome = failure.renderingFailure(for: .axTree(pane: nil), output: .human)

    #expect(
        outputString(outcome)
            == #"{"error":{"code":"pane.ambiguous","message":"multiple panes"}}"# + "\n"
    )
}

@Test
func successfulAndUntypedOutcomesRemainUnchanged() {
    let success = CommandOutcome(stdout: Data("[]\n".utf8), exitCode: 1)
    #expect(success.renderingFailure(for: .doctor, output: .json) == success)

    let legacyFailure = CommandOutcome.failure("legacy")
    #expect(legacyFailure.renderingFailure(for: .tabsList, output: .json) == legacyFailure)
}

@Test
func usageFailureCarriesCodeAndPreservesStderrBlock() {
    let outcome = CLIUsage.outcome(message: "unknown command 'wat'")
    let rendered = outcome.renderingFailure(
        for: .usage(message: "unknown command 'wat'"),
        output: .json
    )

    #expect(outcome.failure?.code == .invalidUsage)
    #expect(outcome.stderr?.hasPrefix("unknown command 'wat'\nusage: deviceterm") == true)
    #expect(outputString(rendered)?.contains(#""code":"cli.invalidUsage""#) == true)
}

@Test
func daemonIntentCodePassesThrough() {
    let outcome = errorOutcome(
        CLIError.daemon(
            code: -32_099,
            message: "intent.notFound: tab 'missing' not found"
        )
    )

    #expect(outcome.failure?.code.rawValue == "intent.notFound")
    #expect(outcome.stderr == "daemon error -32099: intent.notFound: tab 'missing' not found")
}

@Test
func automationRequiredIntentCodePassesThroughItsDaemonCode() {
    let outcome = errorOutcome(
        CLIError.daemon(
            code: -32_011,
            message: "intent.automationRequired: tab.send-input requires automation authority"
        )
    )

    #expect(outcome.failure?.code.rawValue == "intent.automationRequired")
    #expect(
        outcome.stderr
            == "daemon error -32011: intent.automationRequired: "
            + "tab.send-input requires automation authority"
    )
}

@Test
func malformedAXInvocationRendersJSONWithoutFlag() {
    let argv = ["deviceterm", "ax", "point", "bad", "args"]
    let command = CLICommands.parse(argv)
    let outcome = CLIUsage.outcome(message: "usage: deviceterm ax point <x> <y>")
        .renderingFailure(for: command, output: CLICommands.outputMode(for: argv))

    guard case .usage = command else {
        Issue.record("expected malformed AX invocation to produce usage")
        return
    }
    #expect(CLICommands.outputMode(for: argv) == .json)
    #expect(outputString(outcome)?.contains(#""code":"cli.invalidUsage""#) == true)
}

@Test
func sharedCLIFailureClassesStayDistinct() {
    #expect(
        errorOutcome(CLIError.transportUnavailable("connect"))
            .failure?.code == .transportUnavailable
    )
    #expect(
        errorOutcome(CLIError.transportTimeout("timeout"))
            .failure?.code == .transportTimeout
    )
    #expect(
        errorOutcome(CLIError.transportInterrupted("closed"))
            .failure?.code == .transportInterrupted
    )
    #expect(
        errorOutcome(CLIError.invalidResponse("bad response"))
            .failure?.code == .protocolInvalidResponse
    )
    #expect(
        errorOutcome(CLIError.paneNotFound("missing"))
            .failure?.code == .paneNotFound
    )
    #expect(
        errorOutcome(CLIError.paneAmbiguous("many"))
            .failure?.code == .paneAmbiguous
    )
    #expect(
        errorOutcome(CLIError.paneUnavailable("closed"))
            .failure?.code == .paneUnavailable
    )
}

@Test
func daemonCodesMapWithoutParsingProse() {
    #expect(
        errorOutcome(CLIError.daemon(code: -32_602, message: "bad params"))
            .failure?.code == .rpcInvalidParams
    )
    #expect(
        errorOutcome(CLIError.daemon(code: -32_001, message: "bad auth"))
            .failure?.code == .sessionUnauthorized
    )
    #expect(
        errorOutcome(CLIError.daemon(code: -32_012, message: "pane gone"))
            .failure?.code == .paneUnavailable
    )
    #expect(
        errorOutcome(CLIError.daemon(code: -32_020, message: "bridge failed"))
            .failure?.code == .paneBridgeFailed
    )
}

@Test
func decodingErrorMapsToInvalidResponse() {
    do {
        _ = try JSONDecoder().decode(Int.self, from: Data("{}".utf8))
        Issue.record("expected decode failure")
    } catch {
        #expect(errorOutcome(error).failure?.code == .protocolInvalidResponse)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// Doctor check primitives + report formatting.
//
// The runner in main.swift gathers I/O (env reads, socket connect,
// daemon ping, tabs.list, panes.list); the primitives below are pure
// functions of their inputs. Tests pin status semantics + the
// load-bearing fields of the human report.

private func doctorJSON(_ report: Doctor.Report) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(report)
    return try #require(String(data: data, encoding: .utf8))
}

// MARK: - sessionEnvCheck

@Test
func sessionEnvCheckOkForValidUUID() {
    let uuid = "11111111-1111-1111-1111-111111111111"
    let check = Doctor.sessionEnvCheck(value: uuid)
    #expect(check.name == "DEVICETERM_SESSION")
    #expect(check.status == .ok)
    #expect(check.detail == uuid)
}

@Test
func sessionEnvCheckWarnsWhenUnset() {
    let check = Doctor.sessionEnvCheck(value: nil)
    #expect(check.status == .warn)
    #expect(check.detail.contains("outside a deviceterm tab"))
}

@Test
func sessionEnvCheckWarnsOnEmptyString() {
    // Some shells leave variables set-but-empty; treat that as
    // "not in a tab" rather than "malformed UUID."
    let check = Doctor.sessionEnvCheck(value: "")
    #expect(check.status == .warn)
}

@Test
func sessionEnvCheckFailsForNonUUID() {
    let check = Doctor.sessionEnvCheck(value: "not-a-uuid")
    #expect(check.status == .fail)
    #expect(check.detail.contains("not a UUID"))
}

// MARK: - sessionCapCheck

@Test
func sessionCapCheckOkOnPresence() {
    let check = Doctor.sessionCapCheck(value: "AAAAAAAAAA==")
    #expect(check.name == "DEVICETERM_SESSION_CAP")
    #expect(check.status == .ok)
    // The actual token must NOT appear in the report: only the
    // presence + length is surfaced.
    #expect(!check.detail.contains("AAAAAAAAAA=="))
    #expect(check.detail.contains("present"))
    #expect(check.detail.contains("12"))  // length
}

@Test
func sessionCapCheckWarnsWhenUnset() {
    let check = Doctor.sessionCapCheck(value: nil)
    #expect(check.status == .warn)
}

// MARK: - envPathCheck

@Test
func envPathCheckOkForSetValue() {
    let check = Doctor.envPathCheck(
        name: "DEVICETERM_DAEMON_SOCK",
        value: "/Users/test/Library/.../daemon.sock"
    )
    #expect(check.name == "DEVICETERM_DAEMON_SOCK")
    #expect(check.status == .ok)
}

@Test
func envPathCheckWarnsWhenUnset() {
    #expect(Doctor.envPathCheck(name: "FOO", value: nil).status == .warn)
    #expect(Doctor.envPathCheck(name: "FOO", value: "").status == .warn)
}

// MARK: - xcrunCheck

@Test
func xcrunCheckOkWhenPathInsideShimDir() {
    let shim = "/Users/jane/Library/Caches/deviceterm/sessions/abc/bin"
    let check = Doctor.xcrunCheck(
        path: "\(shim)/xcrun",
        shimDir: shim
    )
    #expect(check.status == .ok)
}

@Test
func xcrunCheckWarnsWhenShimNotFirstOnPath() {
    // System xcrun would bypass the boot intercept, a load-bearing
    // gotcha that surfaces here so a stale tab catches it early.
    let check = Doctor.xcrunCheck(
        path: "/usr/bin/xcrun",
        shimDir: "/Users/jane/.../sessions/abc/bin"
    )
    #expect(check.status == .warn)
    #expect(check.detail.contains("PATH"))
}

@Test
func xcrunCheckFailsWhenNotFound() {
    let check = Doctor.xcrunCheck(path: nil, shimDir: nil)
    #expect(check.status == .fail)
    #expect(check.detail.contains("not found"))
}

@Test
func xcrunCheckTreatsMissingShimDirAsWarn() {
    // shimDir nil but xcrun present (outside-tab case): nothing
    // to compare against, so warn.
    let check = Doctor.xcrunCheck(path: "/usr/bin/xcrun", shimDir: nil)
    #expect(check.status == .warn)
}

@Test
func xcrunCheckRejectsSiblingDirectoryWithSharedPrefix() {
    // Regression guard: a hasPrefix check would have called
    // `/foo/bin-old/xcrun` ok when shimDir was `/foo/bin`. The
    // tightened impl compares the resolved binary's parent dir
    // exactly, so a sibling falls into .warn.
    let check = Doctor.xcrunCheck(
        path: "/foo/bin-old/xcrun",
        shimDir: "/foo/bin"
    )
    #expect(check.status == .warn)
}

@Test
func xcrunCheckRejectsDeeperPathInsideShim() {
    // Defense-in-depth: a path one level deeper than shimDir
    // (e.g. `/foo/bin/wrappers/xcrun`) also fails the parent-dir
    // equality. Catches a shim layout that accidentally nests.
    let check = Doctor.xcrunCheck(
        path: "/foo/bin/wrappers/xcrun",
        shimDir: "/foo/bin"
    )
    #expect(check.status == .warn)
}

// MARK: - sessionLivenessCheck

@Test
func sessionLivenessCheckOkWhenFoundInTabs() {
    let check = Doctor.sessionLivenessCheck(
        envSessionId: "11111111-1111-1111-1111-111111111111",
        foundInTabs: true
    )
    #expect(check.status == .ok)
}

@Test
func sessionLivenessCheckFailsWhenSessionNotInTabs() {
    // Stale shell env after a daemon restart: the env carries
    // a sessionId that the daemon no longer knows. Catches it
    // here before any session-scoped command flies and gets a
    // generic `error.unauthorized`.
    let check = Doctor.sessionLivenessCheck(
        envSessionId: "11111111-1111-1111-1111-111111111111",
        foundInTabs: false
    )
    #expect(check.status == .fail)
    #expect(check.detail.contains("not in tabs.list"))
    #expect(check.detail.contains("open a fresh tab"))
}

// MARK: - panesAuthorizationCheck

@Test
func panesAuthorizationCheckOkWhenNoError() {
    let check = Doctor.panesAuthorizationCheck(error: nil)
    #expect(check.status == .ok)
}

@Test
func panesAuthorizationCheckFailsOnDaemonError() {
    // The first call here that proves the cap is honored. Cap
    // mismatch surfaces as an unauthorized error; doctor catches
    // it explicitly rather than letting it slip past as a
    // missing `targets` field.
    let check = Doctor.panesAuthorizationCheck(
        error: "daemon -32001: invalid sessionId or cap"
    )
    #expect(check.status == .fail)
    #expect(check.detail.contains("cap"))
}

// MARK: - socketCheck

@Test
func socketCheckOkWhenReachable() {
    let check = Doctor.socketCheck(path: "/tmp/sock", reachable: true)
    #expect(check.status == .ok)
    #expect(check.detail.contains("/tmp/sock"))
}

@Test
func socketCheckFailsWhenUnreachable() {
    let check = Doctor.socketCheck(path: "/tmp/sock", reachable: false)
    #expect(check.status == .fail)
}

// MARK: - pingCheck

@Test
func pingCheckOkCarriesVersionAndPid() {
    let check = Doctor.pingCheck(wireVersion: "1.0", pid: 12_345, error: nil)
    #expect(check.status == .ok)
    #expect(check.detail.contains("wireVersion=1.0"))
    #expect(check.detail.contains("pid=12345"))
}

@Test
func pingCheckFailsOnError() {
    let check = Doctor.pingCheck(
        wireVersion: nil,
        pid: nil,
        error: "timed out"
    )
    #expect(check.status == .fail)
    #expect(check.detail.contains("timed out"))
}

// MARK: - Report ok derivation

@Test
func reportOkTrueWhenAllChecksOkOrWarn() {
    let report = Doctor.Report(
        checks: [
            Doctor.Check(name: "A", status: .ok, detail: ""),
            Doctor.Check(name: "B", status: .warn, detail: "")
        ],
        session: nil,
        targets: nil
    )
    #expect(report.ok)
}

@Test
func reportOkFalseWhenAnyCheckFails() {
    let report = Doctor.Report(
        checks: [
            Doctor.Check(name: "A", status: .ok, detail: ""),
            Doctor.Check(name: "B", status: .fail, detail: "")
        ],
        session: nil,
        targets: nil
    )
    #expect(!report.ok)
}

@Test
func reportJSONContractAndOptionalOmission() throws {
    let report = Doctor.Report(
        checks: [
            Doctor.Check(
                name: "Daemon socket",
                status: .ok,
                detail: "accepted"
            )
        ],
        session: Doctor.SessionInfo(
            sessionId: "SESSION",
            shortId: "abc123",
            name: "feature"
        ),
        targets: [],
        role: .agent,
        allowedMethods: ["pane.input.tap"]
    )
    let expected = #"{"allowedMethods":["pane.input.tap"],"checks":[{"detail":"accepted","#
        + #""name":"Daemon socket","status":"ok"}],"ok":true,"role":"agent","#
        + #""session":{"name":"feature","sessionId":"SESSION","shortId":"abc123"},"targets":[]}"#
    #expect(try doctorJSON(report) == expected)

    let minimal = Doctor.Report(checks: [], session: nil, targets: nil)
    #expect(try doctorJSON(minimal) == #"{"checks":[],"ok":true}"#)
}

// MARK: - formatHuman

@Test
func formatHumanCarriesBannerAndResultLine() {
    let report = Doctor.Report(
        checks: [Doctor.Check(name: "Foo", status: .ok, detail: "bar")],
        session: nil,
        targets: nil
    )
    let output = Doctor.formatHuman(report)
    #expect(output.contains("deviceterm doctor"))
    #expect(output.contains("Result: ok"))
}

@Test
func formatHumanShowsFailCountOnFailure() {
    let report = Doctor.Report(
        checks: [
            Doctor.Check(name: "A", status: .fail, detail: "x"),
            Doctor.Check(name: "B", status: .fail, detail: "y"),
            Doctor.Check(name: "C", status: .ok, detail: "z")
        ],
        session: nil,
        targets: nil
    )
    let output = Doctor.formatHuman(report)
    #expect(output.contains("Result: fail (2 checks failed)"))
}

@Test
func formatHumanRendersBadgeAndDetail() {
    let report = Doctor.Report(
        checks: [Doctor.Check(name: "MyCheck", status: .warn, detail: "wat")],
        session: nil,
        targets: nil
    )
    let output = Doctor.formatHuman(report)
    #expect(output.contains("[warn]"))
    #expect(output.contains("MyCheck"))
    #expect(output.contains("wat"))
}

@Test
func formatHumanCarriesSessionSection() {
    let report = Doctor.Report(
        checks: [],
        session: Doctor.SessionInfo(
            sessionId: "11111111-1111-1111-1111-111111111111",
            shortId: "ab12cd",
            name: "feature-x"
        ),
        targets: nil
    )
    let output = Doctor.formatHuman(report)
    #expect(output.contains("Session"))
    #expect(output.contains("ab12cd"))
    #expect(output.contains("feature-x"))
    #expect(output.contains("11111111"))
}

@Test
func formatHumanHandlesUnnamedSession() {
    let report = Doctor.Report(
        checks: [],
        session: Doctor.SessionInfo(
            sessionId: "11111111-1111-1111-1111-111111111111",
            shortId: "ab12cd",
            name: nil
        ),
        targets: nil
    )
    let output = Doctor.formatHuman(report)
    #expect(output.contains("(unset)"))
}

@Test
func formatHumanCarriesTargetsSection() {
    let pane = PanesListEntry(
        paneId: "AAAA-...",
        udid: "U1",
        state: .rendering,
        family: "phone",
        shortId: "phn001",
        name: nil
    )
    let report = Doctor.Report(
        checks: [],
        session: nil,
        targets: [pane]
    )
    let output = Doctor.formatHuman(report)
    #expect(output.contains("Targets (1 linked sim pane)"))
    #expect(output.contains("phn001"))
    #expect(output.contains("udid=U1"))
    #expect(output.contains("family=phone"))
}

@Test
func formatHumanForwardPointsAtAgentsPermissionsSection() {
    // The Permissions section carries actual data (role +
    // allowedMethods) when populated, but still references the
    // long-form model in `deviceterm agents` so a caller seeing the
    // summary knows where to read more.
    let report = Doctor.Report(checks: [], session: nil, targets: nil)
    let output = Doctor.formatHuman(report)
    #expect(output.contains("Permissions"))
    #expect(output.contains("deviceterm agents"))
}

@Test
func formatHumanRendersRoleAndAllowedMethodsWhenPopulated() {
    // When daemon.capabilities populates role + allowedMethods, the
    // Permissions section surfaces both axes (role = method-
    // availability anchor; allowedMethods = the set the daemon
    // advertises). Renders count + a 5-verb preview to keep the
    // line scannable even with the full ~28-method registry.
    let report = Doctor.Report(
        checks: [],
        session: nil,
        targets: nil,
        role: .agent,
        allowedMethods: [
            "daemon.ping",
            "daemon.capabilities",
            "tabs.list",
            "panes.list",
            "pane.input.tap",
            "pane.input.swipe",
            "session.close"
        ]
    )
    let output = Doctor.formatHuman(report)
    #expect(output.contains("role             agent"))
    #expect(output.contains("allowedMethods   7:"))
    #expect(output.contains("+ 2 more"))  // 7 - 5 preview
}

@Test
func formatHumanShowsDaemonUnreachableFallbackForPermissions() {
    // When role + allowedMethods are nil (daemon unreachable or
    // out-of-tab + no session creds), the section surfaces an
    // explicit fallback string instead of going blank, so the
    // agent reading the report knows the data wasn't suppressed by
    // a filter.
    let report = Doctor.Report(checks: [], session: nil, targets: nil)
    let output = Doctor.formatHuman(report)
    #expect(output.contains("(daemon unreachable or no session)"))
    #expect(output.contains("(daemon unreachable)"))
}

// MARK: - Parser

@Test
func parseDoctorResolvesToDoctor() {
    #expect(CLICommands.parse(["deviceterm", "doctor"]) == .doctor)
}

@Test
func parseDoctorAcceptsJSONFlag() {
    // The CLI strips --json globally; doctor uses output mode at
    // dispatch time. Parse stays clean.
    #expect(CLICommands.parse(["deviceterm", "doctor", "--json"]) == .doctor)
}

@Test
func parseDoctorTolerateTrailingArgs() {
    // No subcommands; extra args are harmless and don't change
    // dispatch.
    #expect(CLICommands.parse(["deviceterm", "doctor", "extra"]) == .doctor)
}

@Test
func parseTextTreatsDoctorAsLiteral() {
    // Regression guard: `doctor` only fires in the verb position.
    #expect(
        CLICommands.parse(["deviceterm", "text", "doctor"])
        == .text(pane: nil, text: "doctor")
        )
}

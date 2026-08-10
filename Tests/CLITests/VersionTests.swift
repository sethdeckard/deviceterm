// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm version` parser + formatter.
//
// The runner in main.swift gathers I/O (daemon ping for the live wire
// version, ProcessInfo for macOS); the formatter is pure and is
// tested here. Parser test per the standing rule.

private func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return try #require(String(data: data, encoding: .utf8))
}

// MARK: - Parser

@Test
func cliVersionMatchesCurrentRelease() {
    #expect(VersionReportFormat.deviceTermCLIVersion == "0.1.0")
}

@Test
func parseVersionResolvesToVersion() {
    #expect(CLICommands.parse(["deviceterm", "version"]) == .version)
}

@Test
func parseVersionAcceptsJSONFlag() {
    #expect(CLICommands.parse(["deviceterm", "version", "--json"]) == .version)
}

@Test
func parseVersionTolerateTrailingArgs() {
    #expect(CLICommands.parse(["deviceterm", "version", "extra"]) == .version)
}

@Test
func parseTextTreatsVersionAsLiteral() {
    // Verb-position carve-out: `version` fires only at argv[1].
    #expect(
        CLICommands.parse(["deviceterm", "text", "version"])
        == .text(pane: nil, text: "version")
        )
}

// MARK: - Human formatter

@Test
func versionHumanFormatPrintsAllFourRows() {
    let report = VersionReport(
        deviceterm: "0.1.0",
        daemon: "0.1.0",
        rpcWire: "0.1.0",
        macOS: "26.4.1"
    )
    let output = VersionReportFormat.formatHuman(report)
    #expect(output.contains("deviceterm"))
    #expect(output.contains("daemon wire"))
    #expect(output.contains("RPC wire"))
    #expect(output.contains("macOS"))
    #expect(output.contains("0.1.0"))
    #expect(output.contains("26.4.1"))
}

@Test
func versionHumanFormatShowsNotReachableWhenDaemonNil() {
    let report = VersionReport(
        deviceterm: "0.1.0",
        daemon: nil,
        rpcWire: "0.1.0",
        macOS: "26.4.1"
    )
    let output = VersionReportFormat.formatHuman(report)
    #expect(output.contains("(not reachable)"))
}

// MARK: - JSON formatter

@Test
func versionJSONFormatIncludesAllPresentFields() throws {
    let report = VersionReport(
        deviceterm: "0.1.0",
        daemon: "0.1.0",
        rpcWire: "0.1.0",
        macOS: "26.4.1"
    )
    let json = try encode(report)
    let expected = #"{"daemon":"0.1.0","deviceterm":"0.1.0","#
        + #""macOS":"26.4.1","rpcWire":"0.1.0"}"#
    #expect(json == expected)
}

@Test
func versionJSONFormatOmitsNilDaemon() throws {
    // Synthesized encodeIfPresent: nil fields are omitted, not
    // encoded as null.
    let report = VersionReport(
        deviceterm: "0.1.0",
        daemon: nil,
        rpcWire: "0.1.0",
        macOS: "26.4.1"
    )
    let json = try encode(report)
    #expect(json == #"{"deviceterm":"0.1.0","macOS":"26.4.1","rpcWire":"0.1.0"}"#)
}

// MARK: - macOS proxy

@Test
func macOSVersionStringMatchesProcessInfo() {
    // Sanity: the formatter helper just packages
    // ProcessInfo.operatingSystemVersion as a dot-separated
    // string. Confirm leading char is a digit.
    let version = VersionReportFormat.macOSVersionString()
    #expect(version.first?.isNumber == true)
    #expect(version.contains("."))
}

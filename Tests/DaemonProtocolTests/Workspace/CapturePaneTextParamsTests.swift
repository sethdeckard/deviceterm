// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// `ansi` is optional on the wire. A request that omits it must decode as
// a plain capture rather than fail, so a caller that predates the flag
// keeps working against a newer GUI.

@Test
func capturePaneTextRoundTripsTheAnsiFlag() throws {
    let params = AppCommandParams.CapturePaneText(pane: "term", ansi: true)
    let encoded = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(
        AppCommandParams.CapturePaneText.self,
        from: encoded
    )

    #expect(decoded == params)
    #expect(decoded.ansi)
}

@Test
func capturePaneTextDefaultsToPlainWhenAnsiIsAbsent() throws {
    let wire = Data(#"{"pane":"term"}"#.utf8)
    let decoded = try JSONDecoder().decode(
        AppCommandParams.CapturePaneText.self,
        from: wire
    )

    #expect(decoded == AppCommandParams.CapturePaneText(pane: "term"))
    #expect(!decoded.ansi)
}

@Test
func capturePaneTextEncodesAnsiOnTheWire() throws {
    let encoded = try JSONEncoder().encode(
        AppCommandParams.CapturePaneText(pane: "term", ansi: true)
    )
    let json = try #require(String(bytes: encoded, encoding: .utf8))

    #expect(json.contains("\"ansi\":true"))
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// PaneCapabilities is the per-pane capability block carried on
// `pane.create` / `device.attach` and `panes.list`. These pin its
// round-trip and, critically, the skew tolerance of the carrying
// wire shapes: the fields are optional so an older daemon that omits
// them still decodes, and an older client decoding a newer daemon's
// response ignores the extra keys.

@Test
func paneCapabilitiesRoundTrips() throws {
    let caps = PaneCapabilities(
        touch: true,
        key: false,
        text: false,
        button: true,
        rotate: true,
        crown: false,
        accessibility: false,
        location: true
    )
    let data = try JSONEncoder().encode(caps)
    let restored = try JSONDecoder().decode(PaneCapabilities.self, from: data)
    #expect(restored == caps)
}

@Test
func simulatorCapabilitiesAreAllEnabled() {
    let caps = PaneCapabilities.simulator
    #expect(caps.touch && caps.key && caps.text && caps.button)
    #expect(caps.rotate && caps.crown && caps.accessibility && caps.location)
}

@Test
func paneCreateResponseCarriesCapabilitiesAndTarget() throws {
    let response = PaneCreateResponse(
        paneId: "p",
        scale: 1.0,
        family: "phone",
        capabilities: .simulator,
        target: .sim(udid: "ABC")
    )
    let data = try JSONEncoder().encode(response)
    let restored = try JSONDecoder().decode(PaneCreateResponse.self, from: data)
    #expect(restored.capabilities == .simulator)
    #expect(restored.target == .sim(udid: "ABC"))
}

@Test
func paneCreateResponseDecodesOlderDaemonOmittingCapabilities() throws {
    // An older daemon never emits `capabilities` / `target`.
    let json = Data(#"{"paneId":"p","scale":1,"family":"phone"}"#.utf8)
    let response = try JSONDecoder().decode(PaneCreateResponse.self, from: json)
    #expect(response.capabilities == nil)
    #expect(response.target == nil)
    #expect(response.family == "phone")
}

@Test
func panesListEntryCarriesCapabilitiesAndTarget() throws {
    let entry = PanesListEntry(
        paneId: "p",
        udid: "ABC",
        state: .rendering,
        family: "phone",
        capabilities: .simulator,
        target: .sim(udid: "ABC")
    )
    let data = try JSONEncoder().encode(entry)
    let restored = try JSONDecoder().decode(PanesListEntry.self, from: data)
    #expect(restored == entry)
}

@Test
func panesListEntryDecodesOlderDaemonOmittingCapabilities() throws {
    let json = Data(#"{"paneId":"p","udid":"u","state":"booting","family":"watch"}"#.utf8)
    let entry = try JSONDecoder().decode(PanesListEntry.self, from: json)
    #expect(entry.capabilities == nil)
    #expect(entry.target == nil)
}

/// A capability block without `location` must decode with location
/// support disabled.
///
/// Synthesized decoding would require the key and fail the whole
/// enclosing response, since the failure lands on the inner object
/// rather than the optional field that carries it.
@Test("a block without location decodes with location false")
func blockWithoutLocationDecodesAsUnsupported() throws {
    let json = Data("""
    {"touch":true,"key":true,"text":true,"button":true,
     "rotate":true,"crown":true,"accessibility":true}
    """.utf8)
    let caps = try JSONDecoder().decode(PaneCapabilities.self, from: json)
    #expect(caps.touch && caps.crown && caps.accessibility)
    #expect(!caps.location)
}

/// The missing-block fallback keeps the original capability flags but
/// does not assume location support.
@Test("the missing-block fallback withholds location")
func missingBlockFallbackWithholdsLocation() {
    let caps = PaneCapabilities.missingBlockFallback
    #expect(caps.touch && caps.key && caps.text && caps.button)
    #expect(caps.rotate && caps.crown && caps.accessibility)
    #expect(!caps.location)
}

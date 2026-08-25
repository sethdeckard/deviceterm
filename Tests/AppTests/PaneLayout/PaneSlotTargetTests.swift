// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneSlot identity seam: pins that adding the backend-neutral
// `target` accessor changed no existing wire/pasteboard payload, and
// that `target` maps each slot to the right `PaneTarget`. The drag
// pasteboard serializes a `PaneSlot`, so its byte shape is a contract;
// a golden assertion catches any drift from a Codable-synthesis change.

@testable import App
import DaemonProtocol
import Foundation
import Testing

private func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

@Test
func paneSlotSimEncodesAsGoldenShapeUnchanged() throws {
    let data = try canonicalEncoder().encode(PaneSlot.sim(udid: "ABC-123"))
    let json = String(data: data, encoding: .utf8)
    #expect(json == #"{"sim":{"udid":"ABC-123"}}"#)
}

@Test
func paneSlotDeviceEncodesAsGoldenShape() throws {
    let data = try canonicalEncoder().encode(PaneSlot.device(deviceId: "fd00::1"))
    let json = String(data: data, encoding: .utf8)
    #expect(json == #"{"device":{"deviceId":"fd00::1"}}"#)
}

@Test
func paneSlotRoundTripsAllCases() throws {
    let slots: [PaneSlot] = [
        .terminal(TerminalPaneID(value: 1)),
        .sim(udid: "ABC-123"),
        .device(deviceId: "fd00::1")
    ]
    for slot in slots {
        let data = try JSONEncoder().encode(slot)
        let restored = try JSONDecoder().decode(PaneSlot.self, from: data)
        #expect(restored == slot)
    }
}

@Test
func paneSlotTargetMapsEachCase() {
    #expect(PaneSlot.sim(udid: "ABC-123").target == .sim(udid: "ABC-123"))
    #expect(PaneSlot.device(deviceId: "fd00::1").target == .device(deviceId: "fd00::1"))
    #expect(PaneSlot.terminal(TerminalPaneID(value: 1)).target == nil)
}

// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// PaneTarget is the backend-neutral device identity a pane mirrors
// (a CoreSimulator UDID for a sim, a physical deviceId for a
// connected device). These tests pin three things:
//   1. round-trip: encode/decode is lossless for both cases;
//   2. the `key` accessor returns the identity string used for dedup;
//   3. the GOLDEN byte shape: the `.sim` encoding is byte-for-byte
//      what the daemon emits for a sim pane identity, so adding
//      this type changes no existing sim wire payload. A future
//      compiler change to Codable synthesis fails this loudly instead
//      of silently drifting the wire format.

private func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

@Test
func paneTargetRoundTripsBothCases() throws {
    for target in [
        PaneTarget.sim(udid: "ABC-123"),
        PaneTarget.device(deviceId: "00008130-001C195E0E91802E")
    ] {
        let data = try JSONEncoder().encode(target)
        let restored = try JSONDecoder().decode(PaneTarget.self, from: data)
        #expect(restored == target)
    }
}

@Test
func paneTargetKeyIsTheIdentityString() {
    #expect(PaneTarget.sim(udid: "ABC-123").key == "ABC-123")
    #expect(
        PaneTarget.device(deviceId: "00008130-001C195E0E91802E").key
            == "00008130-001C195E0E91802E"
    )
}

@Test
func paneTargetSimEncodesAsGoldenExternalTaggedShape() throws {
    let data = try canonicalEncoder().encode(PaneTarget.sim(udid: "ABC-123"))
    let json = String(data: data, encoding: .utf8)
    #expect(json == #"{"sim":{"udid":"ABC-123"}}"#)
}

@Test
func paneTargetDeviceEncodesAsGoldenExternalTaggedShape() throws {
    let data = try canonicalEncoder().encode(
        PaneTarget.device(deviceId: "00008130-001C195E0E91802E")
    )
    let json = String(data: data, encoding: .utf8)
    #expect(json == #"{"device":{"deviceId":"00008130-001C195E0E91802E"}}"#)
}

@Test
func paneTargetDecodesFromGoldenSimWire() throws {
    let json = Data(#"{"sim":{"udid":"ABC-123"}}"#.utf8)
    let target = try JSONDecoder().decode(PaneTarget.self, from: json)
    #expect(target == .sim(udid: "ABC-123"))
}

// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import Testing

@testable import MirrorPipeline

/// Parsing the feedback target out of the start-stream answer's `streamConfig`.
struct MirrorNegotiatorTests {
    @Test("negotiation fails closed without a stream configuration")
    func failsClosedWithoutConfig() {
        #expect(throws: WireCompatibilityError.missingRequiredField(
            context: "media stream configuration", field: "streamConfig"
        )) {
            _ = try MirrorNegotiator.parseFeedbackTarget(nil)
        }
    }

    @Test("negotiation parses the RTCP identifiers")
    func parsesIdentifiers() throws {
        let target = try MirrorNegotiator.parseFeedbackTarget(.object([
            ("SourcePort", .unsigned(54_321)),
            ("RemoteSSRC", .unsigned(0x1234_5678)),
            ("LocalSSRC", .signed(0x2345_6789))
        ]))
        #expect(target == FeedbackTarget(sourcePort: 54_321, localSSRC: 0x1234_5678, remoteSSRC: 0x2345_6789))
    }

    @Test(
        "negotiation rejects values outside their wire ranges",
        arguments: [
            ("SourcePort", DeviceObject.unsigned(0)),
            ("SourcePort", .unsigned(65_536)),
            ("SourcePort", .signed(-1)),
            ("RemoteSSRC", .unsigned(UInt64(UInt32.max) + 1)),
            ("LocalSSRC", .signed(-1))
        ]
    )
    func rejectsOutOfRange(field: String, value: DeviceObject) {
        var config: [(String, DeviceObject)] = [
            ("SourcePort", .unsigned(54_321)),
            ("RemoteSSRC", .unsigned(0x1234_5678)),
            ("LocalSSRC", .signed(0x2345_6789))
        ]
        guard let index = config.firstIndex(where: { $0.0 == field }) else {
            Issue.record("missing RTCP test field: \(field)")
            return
        }
        config[index] = (field, value)
        #expect(throws: WireCompatibilityError.invalidRequiredValue(
            context: "media stream configuration", field: field
        )) {
            _ = try MirrorNegotiator.parseFeedbackTarget(.object(config))
        }
    }
}

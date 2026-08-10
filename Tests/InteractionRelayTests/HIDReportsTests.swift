// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import Testing

@testable import InteractionRelay

/// Private-encoder tests: the byte layout of the touch and keyboard reports, the
/// per-edge gesture trailer, and the request envelopes. These pin the device
/// wire shapes that only the relay knows.
struct HIDReportsTests {
    @Test("a touchscreen report is 58 bytes and carries the coordinates")
    func touchscreenReportLayout() {
        let report = HIDReports.touchscreenReport(state: HIDReports.contactState, x: 0x1234, y: 0xABCD, timestamp: 0)
        #expect(report.count == 58)
        #expect(report[0] == 0x09) // report id
        #expect(report[3] == HIDReports.contactState)
        #expect(report[4] == 0x34 && report[5] == 0x12) // x little-endian
        #expect(report[6] == 0xCD && report[7] == 0xAB) // y little-endian
    }

    @Test("a plain touch leaves the gesture trailer (bytes 50–57) zeroed")
    func plainTouchTrailerZeroed() {
        let report = HIDReports.touchscreenReport(state: HIDReports.contactState, x: 1, y: 1, timestamp: 0)
        #expect(Array(report[50..<58]) == [UInt8](repeating: 0, count: 8))
    }

    @Test("a system-gesture report differs from a plain touch only in the trailer")
    func gestureDiffersOnlyInTrailer() {
        let plain = HIDReports.touchscreenReport(state: HIDReports.contactState, x: 7, y: 9, timestamp: 42)
        let gesture = HIDReports.touchscreenReport(
            state: HIDReports.contactState, x: 7, y: 9, timestamp: 42, trailer: GestureEdge.bottom.trailer
        )
        #expect(Array(plain[0..<50]) == Array(gesture[0..<50]))
        #expect(Array(gesture[50..<58]) == GestureEdge.bottom.trailer)
    }

    @Test("each edge's trailer differs only in the edge field (report bytes 54–57)")
    func perEdgeTrailers() {
        let edges: [GestureEdge] = [.bottom, .left, .right]
        for edge in edges {
            #expect(edge.trailer.count == 8)
            // Bytes 50–53 (trailer prefix) are constant across edges.
            #expect(Array(edge.trailer[0..<4]) == [0x03, 0x00, 0x00, 0x20])
        }
        // The edge field (trailer bytes 4–7) is distinct per edge.
        #expect(Array(GestureEdge.bottom.trailer[4..<8]) == [0x04, 0x00, 0x00, 0x00])
        #expect(Array(GestureEdge.left.trailer[4..<8]) == [0x00, 0x00, 0x02, 0x00])
        #expect(Array(GestureEdge.right.trailer[4..<8]) == [0x00, 0x10, 0x00, 0x00])
    }

    @Test("a keyboard report is 39 bytes with the usage bit set in the bitmap")
    func keyboardReportBitmap() {
        // Usage 0x0B (KEY_H) sets bit 3 of bitmap byte 1 (= report byte 2).
        let report = HIDReports.keyboardReport(usages: [0x0B], timestamp: 0)
        #expect(report.count == 39)
        #expect(report[0] == 0x01) // report id
        #expect(report[1 + 0x0B / 8] & UInt8(1 << (0x0B % 8)) != 0)
    }

    @Test("the keyboard descriptor declares report id 1 as a 240-key bitmap")
    func keyboardDescriptorShape() {
        // Report id 1 marker, plus the 0xEF (239) usage-maximum the bitmap spans.
        #expect(HIDReports.keyboardDescriptor.contains([0x85, 0x01]) != false)
        #expect(HIDReports.keyboardDescriptor.contains(0x29))
        #expect(HIDReports.keyboardDescriptor.contains(0xEF))
        #expect(HIDReports.keyboardDescriptor.last == 0xC0) // END_COLLECTION
    }

    @Test("the report send envelope addresses a surface with the report blob")
    func sendEnvelope() {
        let envelope = HIDReports.sendReport([0xAA, 0xBB], to: HIDReports.mainTouchscreenServiceID)
        let send = envelope["payload"]?["send"]
        #expect(send?["_0"] == .blob([0xAA, 0xBB]))
        #expect(send?["_1"] == .unsigned(257))
        #expect(envelope["featureIdentifier"]?.text == "com.apple.coredevice.feature.remote.universalhidservice")
    }

    @Test("a button event carries state, usage page, and code")
    func buttonEnvelope() {
        let envelope = HIDReports.buttonEvent(state: 1, usagePage: 0x0C, usageCode: 0x40)
        #expect(envelope["messageType"]?.text == "IndigoButtonEvent")
        #expect(envelope["payload"]?["state"] == .unsigned(1))
        #expect(envelope["payload"]?["usageCode"] == .unsigned(0x40))
    }

    @Test("an orientation request carries the relative step")
    func orientationEnvelope() {
        let envelope = HIDReports.orientationRequest("left")
        #expect(envelope["messageType"]?.text == "OrientationRequest")
        #expect(envelope["payload"]?["rotate"]?["_0"] == .text("left"))
    }
}

private extension Array where Element == UInt8 {
    /// Whether `self` contains `subsequence` as a contiguous run.
    func contains(_ subsequence: [UInt8]) -> Bool {
        guard !subsequence.isEmpty, count >= subsequence.count else { return false }
        for start in 0...(count - subsequence.count)
        where Array(self[start..<start + subsequence.count]) == subsequence {
            return true
        }
        return false
    }
}

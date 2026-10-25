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

    @Test("a button phase resolves its control to the consumer usage", arguments: [
        (ButtonInput.Control.home, UInt64(0x40)),
        (ButtonInput.Control.power, UInt64(0x30)),
        (ButtonInput.Control.assistant, UInt64(0xCF))
    ])
    func buttonPhaseUsage(control: ButtonInput.Control, usage: UInt64) {
        let press = HIDReports.buttonEvent(ButtonInput(control: control, phase: .press))
        let release = HIDReports.buttonEvent(ButtonInput(control: control, phase: .release))
        #expect(press["payload"]?["usagePage"] == .unsigned(0x0C))
        #expect(press["payload"]?["usageCode"] == .unsigned(usage))
        #expect(press["payload"]?["state"] == .unsigned(1))
        #expect(release["payload"]?["state"] == .unsigned(2))
    }

    @Test("a connected-services request carries an empty payload under its name")
    func connectedServicesEnvelope() {
        let envelope = HIDReports.connectedServicesRequest()
        #expect(envelope["messageType"]?.text == "Request")
        #expect(envelope["payload"]?["connectedServices"] == .object([]))
        #expect(envelope["featureIdentifier"]?.text == "com.apple.coredevice.feature.remote.universalhidservice")
    }

    @Test("a connected-services reply maps each touchscreen's display to its id, skipping the rest")
    func touchscreenServicesFromReply() {
        let reply: DeviceObject = .object([
            ("connectedServices", .list([
                .object([("displayUUID", .text("PANEL-A")), ("_ServiceID", .unsigned(257))]),
                .object([("displayUUID", .text("PANEL-B")), ("_ServiceID", .unsigned(0x103))]),
                .object([("Product", .text("CoreDevice keyboard")), ("_ServiceID", .unsigned(512))])
            ]))
        ])
        #expect(HIDReports.touchscreenServices(from: reply) == ["PANEL-A": 257, "PANEL-B": 0x103])
        #expect(HIDReports.touchscreenServices(from: .object([])).isEmpty)
    }

    @Test("an orientation request carries the relative step")
    func orientationEnvelope() {
        let envelope = HIDReports.orientationRequest("left")
        #expect(envelope["messageType"]?.text == "OrientationRequest")
        #expect(envelope["payload"]?["rotate"]?["_0"] == .text("left"))
    }
}

/// The simulator facade: the same reports and envelopes, assembled for a
/// caller with its own transport.
struct SimulatorHIDMessagesTests {
    @Test("the session anchor asks for the session's services")
    func sessionAnchor() {
        #expect(SimulatorHIDMessages.sessionAnchor() == HIDReports.connectedServicesRequest())
    }

    @Test("a touch is a main-touchscreen report with no trailer", arguments: [true, false])
    func plainTouch(contact: Bool) throws {
        let message = SimulatorHIDMessages.touch(contact: contact, x: 0.5, y: 1.0, serviceID: 257)
        let send = try #require(message["payload"]?["send"])
        #expect(send["_1"] == .unsigned(HIDReports.mainTouchscreenServiceID))
        guard case let .blob(report) = try #require(send["_0"]) else {
            Issue.record("the report is not a blob")
            return
        }
        #expect(report.count == 58)
        #expect(report[3] == (contact ? HIDReports.contactState : HIDReports.releaseState))
        #expect(report[6] == 0xFF && report[7] == 0xFF) // y = 1.0 → 65535
        #expect(Array(report[50..<58]) == [UInt8](repeating: 0, count: 8))
    }

    @Test("a gesture touch carries its edge's trailer", arguments: [GestureEdge.bottom, .left, .right])
    func gestureTouch(edge: GestureEdge) throws {
        let message = SimulatorHIDMessages.gestureTouch(contact: true, x: 0.5, y: 0.99, edge: edge, serviceID: 257)
        guard case let .blob(report) = try #require(message["payload"]?["send"]?["_0"]) else {
            Issue.record("the report is not a blob")
            return
        }
        #expect(Array(report[50..<58]) == edge.trailer)
    }

    @Test("a screen's touchscreen is 0x100 plus its id, and no screen means the main one", arguments: [
        (UInt32(0), UInt64(257)),
        (UInt32(1), UInt64(0x101)),
        (UInt32(3), UInt64(0x103))
    ])
    func touchscreenPerScreen(screenID: UInt32, service: UInt64) {
        #expect(SimulatorHIDMessages.touchscreenServiceID(screenID: screenID) == service)
        let message = SimulatorHIDMessages.touch(contact: true, x: 0.5, y: 0.5, serviceID: service)
        #expect(message["payload"]?["send"]?["_1"] == .unsigned(service))
    }

    @Test("two fingers share one report, each under its own identity", arguments: [true, false])
    func twoFingerReport(contact: Bool) throws {
        let message = SimulatorHIDMessages.twoFingerTouch(
            contact: contact,
            first: (0.5, 0.25),
            second: (0.5, 0.75),
            serviceID: 257
        )
        guard case let .blob(report) = try #require(message["payload"]?["send"]?["_0"]) else {
            Issue.record("the report is not a blob")
            return
        }
        #expect(report.count == 58)
        #expect(report[1] == 2) // contact count
        let touching: UInt8 = contact ? 0xC0 : 0x00
        #expect(report[3] == touching | 0x02) // first finger, identity 2
        #expect(report[8] == touching | 0x03) // second finger, identity 3
        #expect(report[6] == 0xFF && report[7] == 0x3F) // first y = 0.25
        #expect(report[11] == 0xFF && report[12] == 0xBF) // second y = 0.75
    }

    @Test("the keyboard registers under the default id and reports to the replied one")
    func keyboard() {
        let registration = HIDReports.createKeyboard(serviceID: HIDReports.keyboardServiceID)
        #expect(SimulatorHIDMessages.registerKeyboard() == registration)
        let reply: DeviceObject = .object([("serviceID", .unsigned(0x1_0000_2042))])
        #expect(SimulatorHIDMessages.registeredKeyboardServiceID(from: reply) == 0x1_0000_2042)
        #expect(SimulatorHIDMessages.registeredKeyboardServiceID(from: .object([])) == HIDReports.keyboardServiceID)
        let report = SimulatorHIDMessages.keyboard(pressed: [0x0B], serviceID: 0x1_0000_2042)
        #expect(report["payload"]?["send"]?["_1"] == .unsigned(0x1_0000_2042))
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

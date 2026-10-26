// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import CoreSimulatorBridge
@testable import Daemon
import Foundation
import InteractionRelay
import Testing
import XPC

@Test("a device object survives the trip through XPC, keys sorted")
func deviceObjectRoundTripsThroughXPC() {
    let identifier = UUID()
    let original: DeviceObject = .object([
        ("text", .text("hello")),
        ("blob", .blob([0x01, 0x02, 0xFF])),
        ("unsigned", .unsigned(UInt64.max)),
        ("signed", .signed(-7)),
        ("flag", .flag(true)),
        ("real", .real(0.25)),
        ("identifier", .identifier(identifier)),
        ("list", .list([.unsigned(1), .text("two")])),
        ("nested", .object([("b", .unsigned(2)), ("a", .unsigned(1))]))
    ])
    let decoded = DeviceObject(xpc: original.xpcObject)
    #expect(decoded["text"] == .text("hello"))
    #expect(decoded["blob"] == .blob([0x01, 0x02, 0xFF]))
    #expect(decoded["unsigned"] == .unsigned(UInt64.max))
    #expect(decoded["signed"] == .signed(-7))
    #expect(decoded["flag"] == .flag(true))
    #expect(decoded["real"] == .real(0.25))
    #expect(decoded["list"] == .list([.unsigned(1), .text("two")]))
    #expect(decoded["nested"] == .object([("a", .unsigned(1)), ("b", .unsigned(2))]))
    #expect(decoded["identifier"] == .identifier(identifier))
}

@Test("an empty blob encodes and decodes as empty data")
func emptyBlobRoundTrips() {
    #expect(DeviceObject(xpc: DeviceObject.blob([]).xpcObject) == .blob([]))
}

@Test("only the home-indicator edges have a gesture", arguments: [
    (0, nil),
    (1, nil),
    (2, GestureEdge.left),
    (3, GestureEdge.bottom),
    (4, GestureEdge.right)
] as [(Int, GestureEdge?)])
func indigoEdgeMapsToGestureEdge(edge: Int, expected: GestureEdge?) {
    #expect(SimRemoteHIDMessages.gestureEdge(indigoEdge: edge) == expected)
}

@Test("a top-edge gesture is sent as a plain touch, with no trailer")
func topEdgeGestureIsAPlainTouch() throws {
    let messages = SimRemoteHIDMessages(hasHomeButton: false)
    let gesture = DeviceObject(xpc: messages.gestureTouch(withContact: true, x: 0.5, y: 0.01, edge: 1, serviceID: 257))
    guard case let .blob(report) = try #require(gesture["payload"]?["send"]?["_0"]) else {
        Issue.record("the report is not a blob")
        return
    }
    #expect(Array(report[50..<58]) == [UInt8](repeating: 0, count: 8))
}

@Test("hardware buttons map onto the device controls", arguments: [
    (CSBHardwareButton.home, ButtonInput.Control.home),
    (.lock, .power),
    (.sideButton, .power),
    (.siri, .assistant),
    (.applePay, .power),
    (.digitalCrown, nil)
] as [(CSBHardwareButton, ButtonInput.Control?)])
func hardwareButtonMapsToControl(button: CSBHardwareButton, expected: ButtonInput.Control?) {
    #expect(SimRemoteHIDMessages.control(for: button, hasHomeButton: false) == expected)
}

@Test("Apple Pay double-presses Home on a device with a Home button")
func applePayUsesHomeWhereThereIsOne() {
    #expect(SimRemoteHIDMessages.control(for: .applePay, hasHomeButton: true) == .home)
    #expect(SimRemoteHIDMessages.control(for: .lock, hasHomeButton: true) == .power)
}

@Test("Apple Pay is two presses, every other button one")
func applePayIsADoublePress() {
    let messages = SimRemoteHIDMessages(hasHomeButton: false)
    #expect(messages.pressCount(forButton: CSBHardwareButton.applePay.rawValue) == 2)
    #expect(messages.pressCount(forButton: CSBHardwareButton.lock.rawValue) == 1)
    #expect(messages.pressCount(forButton: CSBHardwareButton.home.rawValue) == 1)
}

@Test("a button with no device control has no daemon message")
func unmappedButtonHasNoMessage() {
    let messages = SimRemoteHIDMessages(hasHomeButton: false)
    #expect(messages.buttonEvent(forButton: CSBHardwareButton.digitalCrown.rawValue, down: true) == nil)
    #expect(messages.buttonEvent(forButton: 99, down: true) == nil)
    let home = messages.buttonEvent(forButton: CSBHardwareButton.home.rawValue, down: true)
    #expect(home.map { DeviceObject(xpc: $0)["messageType"] } == .text("IndigoButtonEvent"))
}

@Test(
    "a key event reaches XPC with its usage intact, including ones a keyboard report can't carry",
    arguments: [UInt32(0x0B), 0xE1, 0xF0, 0x1FF]
)
func keyEventCarriesItsUsage(usage: UInt32) {
    let messages = SimRemoteHIDMessages(hasHomeButton: false)
    let event = DeviceObject(xpc: messages.keyboardEvent(forUsage: usage, down: true))
    #expect(event["messageType"] == .text("IndigoKeyboardButtonEvent"))
    #expect(event["payload"]?["usageCode"] == .unsigned(UInt64(usage)))
    #expect(messages.keyboardServiceName == SimulatorHIDMessages.keyboardService)
}

@Test("a held contact and its display UUID stay on the panel it went down on")
func touchPanelKeepsNamesTogether() {
    let held = (UInt32(3), Optional("PANEL-3"))
    let bound = (UInt32(1), Optional("PANEL-1"))
    let unaddressed = (UInt32(0), String?.none)
    let holding = SimDeviceBackend.touchPanel(
        foldable: true, holding: true, heldOn: held, bound: bound, unaddressed: unaddressed
    )
    #expect(holding.0 == 3 && holding.1 == "PANEL-3")
    let fresh = SimDeviceBackend.touchPanel(
        foldable: true, holding: false, heldOn: held, bound: bound, unaddressed: unaddressed
    )
    #expect(fresh.0 == 1 && fresh.1 == "PANEL-1")
    let single = SimDeviceBackend.touchPanel(
        foldable: false, holding: true, heldOn: held, bound: bound, unaddressed: unaddressed
    )
    #expect(single.0 == 0 && single.1 == nil)
}

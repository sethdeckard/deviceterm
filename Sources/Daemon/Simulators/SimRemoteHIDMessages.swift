// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import CoreGraphics
import CoreSimulatorBridge
import Foundation
import InteractionRelay
import XPC

/// The messages a simulator's HID daemon takes, in the form `SimHIDClient`
/// carries them: the relay's own device vocabulary, encoded as native XPC.
final class SimRemoteHIDMessages: NSObject, CSBRemoteHIDMessageBuilding {
    let touchServiceName = SimulatorHIDMessages.touchService
    let buttonServiceName = SimulatorHIDMessages.buttonService
    let keyboardServiceName = SimulatorHIDMessages.keyboardService
    /// Whether the device has a physical Home button, which is the one Apple
    /// Pay double-presses there.
    let hasHomeButton: Bool

    init(hasHomeButton: Bool) {
        self.hasHomeButton = hasHomeButton
    }

    /// The gesture edge for a raw `IndigoHIDEdge`, or nil for top and none.
    /// The device vocabulary has gestures only for the home-indicator edges;
    /// a swipe from the top reaches the system as a plain touch.
    static func gestureEdge(indigoEdge edge: Int) -> GestureEdge? {
        switch edge {
        case 2:
            .left

        case 3:
            .bottom

        case 4:
            .right

        default:
            nil
        }
    }

    /// The device control for a `CSBHardwareButton`, or nil for one the
    /// device vocabulary has no event for. Lock and the side button are the
    /// same power button. Apple Pay is a double press of the Home button on a
    /// device with one, and of the side button otherwise.
    static func control(for button: CSBHardwareButton, hasHomeButton: Bool) -> ButtonInput.Control? {
        switch button {
        case .home:
            .home

        case .lock, .sideButton:
            .power

        case .applePay:
            hasHomeButton ? .home : .power

        case .siri:
            .assistant

        case .digitalCrown:
            nil

        @unknown default:
            nil
        }
    }

    func sessionAnchor() -> xpc_object_t {
        SimulatorHIDMessages.sessionAnchor().xpcObject
    }

    func touchscreenServices(fromAnchorReply reply: xpc_object_t) -> [String: NSNumber] {
        SimulatorHIDMessages.touchscreenServices(fromAnchorReply: DeviceObject(xpc: reply))
            .mapValues { NSNumber(value: $0) }
    }

    func touchscreenServiceID(forScreenID screenID: UInt32) -> UInt64 {
        SimulatorHIDMessages.touchscreenServiceID(screenID: screenID)
    }

    func touch(withContact contact: Bool, x: Double, y: Double, serviceID: UInt64) -> xpc_object_t {
        SimulatorHIDMessages.touch(contact: contact, x: x, y: y, serviceID: serviceID).xpcObject
    }

    func twoFingerTouch(withContact contact: Bool, first: CGPoint, second: CGPoint, serviceID: UInt64) -> xpc_object_t {
        SimulatorHIDMessages.twoFingerTouch(
            contact: contact,
            first: (first.x, first.y),
            second: (second.x, second.y),
            serviceID: serviceID
        ).xpcObject
    }

    func gestureTouch(withContact contact: Bool, x: Double, y: Double, edge: Int, serviceID: UInt64) -> xpc_object_t {
        guard let gestureEdge = Self.gestureEdge(indigoEdge: edge) else {
            return touch(withContact: contact, x: x, y: y, serviceID: serviceID)
        }
        return SimulatorHIDMessages.gestureTouch(
            contact: contact,
            x: x,
            y: y,
            edge: gestureEdge,
            serviceID: serviceID
        ).xpcObject
    }

    func keyboardEvent(forUsage usage: UInt32, down: Bool) -> xpc_object_t {
        SimulatorHIDMessages.key(usage: UInt16(truncatingIfNeeded: usage), down: down).xpcObject
    }

    func keyboardRegistration() -> xpc_object_t {
        SimulatorHIDMessages.registerKeyboard().xpcObject
    }

    func keyboardServiceID(fromReply reply: xpc_object_t) -> NSNumber? {
        SimulatorHIDMessages.registeredKeyboardServiceID(from: DeviceObject(xpc: reply)).map { NSNumber(value: $0) }
    }

    func keyboardReport(withPressedUsages usages: Set<NSNumber>, serviceID: UInt64) -> xpc_object_t {
        let pressed = Set(usages.compactMap { UInt16(exactly: $0.uint32Value) })
        return SimulatorHIDMessages.keyboard(pressed: pressed, serviceID: serviceID).xpcObject
    }

    func keyboardRemoval(forServiceID serviceID: UInt64) -> xpc_object_t {
        SimulatorHIDMessages.removeKeyboard(serviceID: serviceID).xpcObject
    }

    func pressCount(forButton button: Int) -> Int {
        CSBHardwareButton(rawValue: button) == .applePay ? 2 : 1
    }

    func buttonEvent(forButton button: Int, down: Bool) -> xpc_object_t? {
        guard let hardware = CSBHardwareButton(rawValue: button),
            let control = Self.control(for: hardware, hasHomeButton: hasHomeButton) else {
            return nil
        }
        return SimulatorHIDMessages.button(ButtonInput(control: control, phase: down ? .press : .release)).xpcObject
    }
}
